--- Add master clip to timeline with single-undo multi-channel insertion
--
-- ARCHITECTURAL CONTEXT:
-- This file is part of the event-sourced command system. All state changes
-- must go through commands so they can be persisted, undone, and replayed.
--
-- Why "packets" (command parameters)?
--   - Commands are serialized to SQLite for undo/redo/replay
--   - Parameters must survive serialization across app restarts
--   - Packet format allows command_manager to persist/restore state
--
-- Why register()?
--   - command_manager.lua calls register() during initialization
--   - This populates the command_executors table with our executor function
--   - When someone calls execute("AddClipToTimeline", params), it routes here
--
-- Why command_manager vs command?
--   - command.lua: Command class (data packet with parameters)
--   - command_manager.lua: Orchestrates execution, undo/redo, persistence
--
-- ALGORITHM:
-- 1. Extract parameters from command packet
-- 2. Inspect media to determine channels (video? audio? how many?)
-- 3. Begin undo group (makes all insertions atomic)
-- 4. Insert video channel if present
-- 5. Insert audio channels if present (loop over channel count)
-- 6. Link all inserted clips together (so they move as one unit)
-- 7. End undo group (commit transaction)
--
-- @file add_clip_to_timeline.lua
local M = {}

-- Module dependencies (aligned for clarity)
local uuid_module            = require("uuid")
local command_manager_module = require("core.command_manager")
local command_module         = require("command")
local clip_media_module      = require("core.utils.clip_media")
local track_resolver_module  = require("core.utils.track_resolver")

--------------------------------------------------------------------------------
-- Helper: Execute Insert/Overwrite for a single channel
--
-- Why so many parameters?
--   This function is called N times (once per channel) in a loop.
--   Each call creates a timeline clip from a master clip.
--
-- Parameters:
--   command_type: "Insert" or "Overwrite" (validated by caller)
--   base_payload: Shared data for all channels (source timing, media_id, etc)
--   track_id: Which timeline track to insert into
--   sequence_id: Which timeline sequence we're editing
--   insert_pos: Timecode position for insertion
--   project_id: Database project scope
--   channel_type: "video" or "audio" (for linking later)
--   channel_index: Audio channel number (0, 1, 2...) or nil for video
--   clip_ids_out: Accumulator table - we append {clip_id, role} for linking
--
-- What it does:
--   1. Generate unique clip_id for this timeline clip
--   2. Build Insert/Overwrite command with all required parameters
--   3. Execute command through command_manager (persists to database)
--   4. Store clip_id in accumulator for linking step
--------------------------------------------------------------------------------
local function execute_channel_insertion(
    command_type,
    base_payload,
    track_id,
    sequence_id,
    insert_pos,
    project_id,
    channel_type,
    channel_index,
    clip_ids_out
)
    local clip_id = uuid_module.generate()

    -- Insert and Overwrite use different parameter names for position
    -- Insert: "insert_time" (ripples timeline)
    -- Overwrite: "overwrite_time" (replaces existing content)
    local time_param = (command_type == "Overwrite") and "overwrite_time" or "insert_time"

    -- Build command packet for Insert or Overwrite
    -- Command system requires all parameters be set explicitly (no defaults)
    local cmd = command_module.create(command_type, project_id)
    cmd:set_parameter("sequence_id", sequence_id)
    cmd:set_parameter("track_id", track_id)
    cmd:set_parameter("master_clip_id", base_payload.master_clip_id)
    cmd:set_parameter("duration", base_payload.duration)
    cmd:set_parameter("source_in", base_payload.source_in)
    cmd:set_parameter("source_out", base_payload.source_out)
    cmd:set_parameter("project_id", base_payload.project_id)
    cmd:set_parameter("clip_id", clip_id)
    cmd:set_parameter(time_param, insert_pos)

    -- Optional parameters (only set if present in base_payload)
    if base_payload.media_id then cmd:set_parameter("media_id", base_payload.media_id) end
    if base_payload.clip_name then cmd:set_parameter("clip_name", base_payload.clip_name) end
    if base_payload.advance_playhead then cmd:set_parameter("advance_playhead", true) end
    if channel_index ~= nil then cmd:set_parameter("channel", channel_index) end

    -- Execute Insert or Overwrite command
    -- This persists to database, updates timeline state, enables undo
    local result = command_manager_module.execute(cmd)
    if not (result and result.success) then
        error(string.format("AddClipToTimeline: %s command failed: %s",
            command_type, result and result.error_message or "unknown error"))
    end

    -- Record clip_id for linking step
    -- When video+audio are inserted, they must be linked so they move together
    table.insert(clip_ids_out, {clip_id = clip_id, role = channel_type, time_offset = 0})
end

--------------------------------------------------------------------------------
-- Command Registration
--
-- command_manager.lua calls this during initialization to register our executor.
-- After registration, calling command_manager.execute("AddClipToTimeline", {...})
-- will route to the executor function defined below.
--------------------------------------------------------------------------------
function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddClipToTimeline"] = function(command)
        -- ====================================================================
        -- PARAMETER EXTRACTION
        -- ====================================================================
        -- Commands are data packets with named parameters
        -- This allows serialization to SQLite for undo/redo/replay
        -- Caller (usually UI code) built this packet and passed it to command_manager

        local clip           = assert(command:get_parameter("clip"), "AddClipToTimeline: no clip provided")
        local timeline_state = assert(command:get_parameter("timeline_state"), "AddClipToTimeline: timeline state not available")
        local sequence_id    = assert(command:get_parameter("sequence_id"), "AddClipToTimeline: missing sequence_id")
        local project_id     = assert(command:get_parameter("project_id") or command.project_id, "AddClipToTimeline: missing project_id")
        local insert_pos     = assert(command:get_parameter("insert_pos"), "AddClipToTimeline: missing insert position")
        local command_type   = assert(command:get_parameter("command_type"), "AddClipToTimeline: missing command_type")

        -- Validate command_type is a known Insert/Overwrite command
        -- These are the only valid timeline insertion modes
        assert(command_type == "Insert" or command_type == "Overwrite",
            "AddClipToTimeline: command_type must be 'Insert' or 'Overwrite', got: " .. tostring(command_type))

        local advance_playhead = command:get_parameter("advance_playhead")

        -- Resolve media reference
        -- Clip references media by media_id, lookup table provides media object
        local media_lookup = command:get_parameter("media_lookup")
        local media = assert(clip.media or (clip.media_id and media_lookup and media_lookup[clip.media_id]),
            "AddClipToTimeline: missing media")
        local media_id = assert(clip.media_id or media.id, "AddClipToTimeline: missing media_id")

        -- Extract source timing from clip
        -- source_in/source_out define the trim range within the media file
        local source_in  = assert(clip.source_in, "AddClipToTimeline: missing source_in")
        local source_out = assert(clip.source_out or clip.duration or media.duration, "AddClipToTimeline: missing source_out")
        local duration   = source_out - source_in
        assert(duration.frames and duration.frames > 0, "AddClipToTimeline: invalid duration")

        -- ====================================================================
        -- MEDIA INSPECTION
        -- ====================================================================
        -- Determine which channels to insert (video? audio? how many audio?)
        local has_video = clip_media_module.has_video(clip, media)
        local has_audio = clip_media_module.has_audio(clip, media)
        local audio_channel_count = has_audio and clip_media_module.audio_channel_count(clip, media) or 0

        -- ====================================================================
        -- PAYLOAD CONSTRUCTION
        -- ====================================================================
        -- Build shared data packet for all channel insertions
        -- Why? Video and audio channels share source timing, media_id, etc.
        -- Instead of repeating these 7 fields in execute_channel_insertion calls,
        -- we bundle them once and pass the bundle
        local base_payload = {
            media_id = media_id,
            master_clip_id = clip.clip_id,
            project_id = clip.project_id or project_id,
            duration = duration,
            source_in = source_in,
            source_out = source_out,
            clip_name = clip.name,
            advance_playhead = advance_playhead
        }

        -- Accumulator for clip IDs created during insertion
        -- After inserting video+audio, we link them so they move together
        local clip_ids = {}

        -- ====================================================================
        -- ALGORITHM: Atomic multi-channel insertion
        -- ====================================================================
        command_manager_module.begin_undo_group(string.format("Add %s to timeline", clip.name or "clip"))

        -- Insert video channel if media contains video
        if has_video then
            local video_track = track_resolver_module.resolve_video_track(timeline_state, 0)
            execute_channel_insertion(command_type, base_payload, video_track.id, sequence_id, insert_pos, project_id, "video", nil, clip_ids)
        end

        -- Insert audio channels if media contains audio
        -- Loop over channel count (stereo = 2 channels, mono = 1, etc)
        if has_audio then
            for ch = 0, audio_channel_count - 1 do
                local audio_track = track_resolver_module.resolve_audio_track(timeline_state, ch)
                execute_channel_insertion(command_type, base_payload, audio_track.id, sequence_id, insert_pos, project_id, "audio", ch, clip_ids)
            end
        end

        -- Link all inserted clips together (video + audio = linked group)
        -- Linked clips move/trim/delete together (professional NLE behavior)
        if #clip_ids > 1 then
            local link_cmd = command_module.create("LinkClips", project_id)
            link_cmd:set_parameter("clips", clip_ids)
            local link_result = command_manager_module.execute(link_cmd)
            if not (link_result and link_result.success) then
                error(string.format("AddClipToTimeline: LinkClips failed: %s",
                    link_result and link_result.error_message or "unknown error"))
            end
        end

        command_manager_module.end_undo_group()
        -- ====================================================================

        return {success = true}
    end

    -- Return executor function to command_manager
    -- command_manager stores this in command_executors["AddClipToTimeline"]
    return {
        executor = command_executors["AddClipToTimeline"]
    }
end

return M
