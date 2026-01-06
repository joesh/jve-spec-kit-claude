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

--J I want the following ids to have a syntactic convention showing they're module includes. like, say, uuid_module. I also want all the ='s lined up.
--J Why do we need all of these? What do they each do? What's the diff betw command_manager and command? Why is one in core and not the other?
local command_manager_module = require("core.command_manager")
local clip_media_module      = require("core.utils.clip_media")
local track_resolver_module  = require("core.utils.track_resolver")
local timeline_ops_module    = require("core.utils.timeline_ops")

--J what are we registering? why? who's going to call this?
function M.register(command_executors, command_undoers, db, set_last_error)
    --J why? where does command come from?
    command_executors["AddClipToTimeline"] = function(command)
        -- ====================================================================
        -- PARAMETER EXTRACTION
        -- ====================================================================
        -- Commands are data packets with named parameters
        -- This allows serialization to SQLite for undo/redo/replay
        -- Caller (usually UI code) built this packet and passed it to command_manager

        --J from where are we extracting? why so many parameters? why are they in a packet?
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
        -- CLIP SOURCE DATA
        -- ====================================================================
        --J wtf do we have a payload? why do we need this level of indirection
        -- Build shared data packet for all channel insertions
        -- Why? Video and audio channels share source timing, media_id, etc.
        -- Instead of repeating these 7 fields in timeline_ops calls,
        -- we bundle them once and pass the bundle
        local clip_source = {
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

        -- Insert video channel if present
        if has_video then
            local video_track = track_resolver_module.resolve_video_track(timeline_state, 0)
            local clip_id = timeline_ops_module.add_clip_to_track(command_type, video_track.id, insert_pos, sequence_id, clip_source, nil)
            table.insert(clip_ids, {clip_id = clip_id, role = "video", time_offset = 0})
        end

        -- Insert audio channels if present
        if has_audio then
            for ch = 0, audio_channel_count - 1 do
                local audio_track = track_resolver_module.resolve_audio_track(timeline_state, ch)
                local clip_id = timeline_ops_module.add_clip_to_track(command_type, audio_track.id, insert_pos, sequence_id, clip_source, ch)
                table.insert(clip_ids, {clip_id = clip_id, role = "audio", time_offset = 0})
            end
        end

        -- Link all channels together
        timeline_ops_module.link_clips(clip_ids, clip_source.project_id)

        command_manager_module.end_undo_group()
        -- ====================================================================

        return {success = true}
    end

    --J explain this line
    -- Return executor function to command_manager
    -- command_manager stores this in command_executors["AddClipToTimeline"]
    return {
        executor = command_executors["AddClipToTimeline"]
    }
end

return M
