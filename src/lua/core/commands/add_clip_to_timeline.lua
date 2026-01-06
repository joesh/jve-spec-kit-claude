--- Add master clip to timeline with single-undo multi-channel insertion
--
-- Responsibilities:
-- - Add master clip to timeline at playhead position
-- - Handle Insert and Overwrite modes
-- - Resolve track selection (video track 0, audio tracks 0..N)
-- - Execute atomic multi-channel insertion (video + audio = one undo)
--
-- Non-goals:
-- - UI selection management (handled by caller)
-- - Direct database access (use command composition)
--
-- Invariants:
-- - Command type must be "Insert" or "Overwrite"
-- - Timeline state must be available
-- - All clips inserted within undo group (video + audio = one undo)
-- - Undo group rollback ensures atomicity on failure
--
-- @file add_clip_to_timeline.lua
local M = {}
local uuid = require("uuid")
local command_manager = require("core.command_manager")
local Command = require("command")
local clip_media = require("core.utils.clip_media")
local track_resolver = require("core.utils.track_resolver")

-- Module-level helper: Execute Insert/Overwrite command for a single channel
-- This is mechanical boilerplate, not algorithm
local function execute_channel_insertion(command_type, base_payload, track_id, sequence_id, insert_pos, project_id, channel_type, channel_index, clip_ids_out)
    local clip_id = uuid.generate()
    local time_param = (command_type == "Overwrite") and "overwrite_time" or "insert_time"

    local cmd = Command.create(command_type, project_id)
    cmd:set_parameter("sequence_id", sequence_id)
    cmd:set_parameter("track_id", track_id)
    cmd:set_parameter("master_clip_id", base_payload.master_clip_id)
    cmd:set_parameter("duration", base_payload.duration)
    cmd:set_parameter("source_in", base_payload.source_in)
    cmd:set_parameter("source_out", base_payload.source_out)
    cmd:set_parameter("project_id", base_payload.project_id)
    cmd:set_parameter("clip_id", clip_id)
    cmd:set_parameter(time_param, insert_pos)

    if base_payload.media_id then cmd:set_parameter("media_id", base_payload.media_id) end
    if base_payload.clip_name then cmd:set_parameter("clip_name", base_payload.clip_name) end
    if base_payload.advance_playhead then cmd:set_parameter("advance_playhead", true) end
    if channel_index ~= nil then cmd:set_parameter("channel", channel_index) end

    local result = command_manager.execute(cmd)
    if not (result and result.success) then
        error(string.format("AddClipToTimeline: %s command failed: %s",
            command_type, result and result.error_message or "unknown error"))
    end

    table.insert(clip_ids_out, {clip_id = clip_id, role = channel_type, time_offset = 0})
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddClipToTimeline"] = function(command)
        -- Extract and validate parameters
        local clip = assert(command:get_parameter("clip"), "AddClipToTimeline: no clip provided")
        local timeline_state = assert(command:get_parameter("timeline_state"), "AddClipToTimeline: timeline state not available")
        local sequence_id = assert(command:get_parameter("sequence_id"), "AddClipToTimeline: missing sequence_id")
        local project_id = assert(command:get_parameter("project_id") or command.project_id, "AddClipToTimeline: missing project_id")
        local insert_pos = assert(command:get_parameter("insert_pos"), "AddClipToTimeline: missing insert position")
        local command_type = assert(command:get_parameter("command_type"), "AddClipToTimeline: missing command_type")
        assert(command_type == "Insert" or command_type == "Overwrite", "AddClipToTimeline: unsupported command_type")
        local advance_playhead = command:get_parameter("advance_playhead")

        -- Resolve media reference
        local media_lookup = command:get_parameter("media_lookup")
        local media = assert(clip.media or (clip.media_id and media_lookup and media_lookup[clip.media_id]),
            "AddClipToTimeline: missing media")
        local media_id = assert(clip.media_id or media.id, "AddClipToTimeline: missing media_id")

        -- Extract source timing
        local source_in = assert(clip.source_in, "AddClipToTimeline: missing source_in")
        local source_out = assert(clip.source_out or clip.duration or media.duration, "AddClipToTimeline: missing source_out")
        local duration = source_out - source_in
        assert(duration.frames and duration.frames > 0, "AddClipToTimeline: invalid duration")

        -- Inspect media to determine what channels to insert
        local has_video = clip_media.has_video(clip, media)
        local has_audio = clip_media.has_audio(clip, media)
        local audio_channel_count = has_audio and clip_media.audio_channel_count(clip, media) or 0

        -- Build base payload (shared by all channels)
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

        -- Track created clip IDs for linking
        local clip_ids = {}

        -- ========================================
        -- ALGORITHM: Atomic multi-channel insertion
        -- ========================================
        command_manager.begin_undo_group(string.format("Add %s to timeline", clip.name or "clip"))

        -- Insert video channel if present
        if has_video then
            local video_track = track_resolver.resolve_video_track(timeline_state, 0)
            execute_channel_insertion(command_type, base_payload, video_track.id, sequence_id, insert_pos, project_id, "video", nil, clip_ids)
        end

        -- Insert audio channels if present
        if has_audio then
            for ch = 0, audio_channel_count - 1 do
                local audio_track = track_resolver.resolve_audio_track(timeline_state, ch)
                execute_channel_insertion(command_type, base_payload, audio_track.id, sequence_id, insert_pos, project_id, "audio", ch, clip_ids)
            end
        end

        -- Link all channels together (single linked group)
        if #clip_ids > 1 then
            local link_cmd = Command.create("LinkClips", project_id)
            link_cmd:set_parameter("clips", clip_ids)
            local link_result = command_manager.execute(link_cmd)
            if not (link_result and link_result.success) then
                error(string.format("AddClipToTimeline: LinkClips failed: %s",
                    link_result and link_result.error_message or "unknown error"))
            end
        end

        command_manager.end_undo_group()
        -- ========================================

        return {success = true}
    end

    return {
        executor = command_executors["AddClipToTimeline"]
    }
end

return M
