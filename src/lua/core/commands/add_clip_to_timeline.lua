local M = {}

local uuid_module            = require("uuid")
local command_manager_module = require("core.command_manager")
local command_module         = require("command")
local clip_media_module      = require("core.utils.clip_media")
local track_resolver_module  = require("core.utils.track_resolver")

local function set_insert_overwrite_parameters(cmd, command_type, track_id, sequence_id, insert_pos, clip_source, channel)
    local clip_id = uuid_module.generate()
    local time_param = (command_type == "Overwrite") and "overwrite_time" or "insert_time"

    cmd:set_parameter("sequence_id", sequence_id)
    cmd:set_parameter("track_id", track_id)
    cmd:set_parameter("master_clip_id", clip_source.master_clip_id)
    cmd:set_parameter("duration", clip_source.duration)
    cmd:set_parameter("source_in", clip_source.source_in)
    cmd:set_parameter("source_out", clip_source.source_out)
    cmd:set_parameter("project_id", clip_source.project_id)
    cmd:set_parameter("clip_id", clip_id)
    cmd:set_parameter(time_param, insert_pos)

    if clip_source.media_id then cmd:set_parameter("media_id", clip_source.media_id) end
    if clip_source.clip_name then cmd:set_parameter("clip_name", clip_source.clip_name) end
    if clip_source.advance_playhead then cmd:set_parameter("advance_playhead", true) end
    if channel ~= nil then cmd:set_parameter("channel", channel) end

    return clip_id
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddClipToTimeline"] = function(command)
        local clip = assert(command:get_parameter("clip"), "AddClipToTimeline: no clip provided")
        local timeline_state = assert(command:get_parameter("timeline_state"), "AddClipToTimeline: timeline state not available")
        local sequence_id = assert(command:get_parameter("sequence_id"), "AddClipToTimeline: missing sequence_id")
        local project_id = assert(command:get_parameter("project_id") or command.project_id, "AddClipToTimeline: missing project_id")
        local insert_pos = assert(command:get_parameter("insert_pos"), "AddClipToTimeline: missing insert position")
        local command_type = assert(command:get_parameter("command_type"), "AddClipToTimeline: missing command_type")
        assert(command_type == "Insert" or command_type == "Overwrite", "AddClipToTimeline: command_type must be Insert or Overwrite")

        local advance_playhead = command:get_parameter("advance_playhead")
        local media_lookup = command:get_parameter("media_lookup")
        local media = assert(clip.media or (clip.media_id and media_lookup and media_lookup[clip.media_id]), "AddClipToTimeline: missing media")
        local media_id = assert(clip.media_id or media.id, "AddClipToTimeline: missing media_id")

        local source_in = assert(clip.source_in, "AddClipToTimeline: missing source_in")
        local source_out = assert(clip.source_out or clip.duration or media.duration, "AddClipToTimeline: missing source_out")
        local duration = source_out - source_in
        assert(duration.frames and duration.frames > 0, "AddClipToTimeline: invalid duration")

        local has_video = clip_media_module.has_video(clip, media)
        local has_audio = clip_media_module.has_audio(clip, media)
        local audio_channel_count = has_audio and clip_media_module.audio_channel_count(clip, media) or 0

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

        local clip_ids = {}

        command_manager_module.begin_undo_group(string.format("Add %s to timeline", clip.name or "clip"))

        if has_video then
            local video_track = track_resolver_module.resolve_video_track(timeline_state, 0)
            local video_cmd = command_module.create(command_type, project_id)
            local clip_id = set_insert_overwrite_parameters(video_cmd, command_type, video_track.id, sequence_id, insert_pos, clip_source, nil)
            local result = command_manager_module.execute(video_cmd)
            assert(result and result.success, string.format("AddClipToTimeline: %s failed: %s", command_type, result and result.error_message or "unknown"))
            table.insert(clip_ids, {clip_id = clip_id, role = "video", time_offset = 0})
        end

        if has_audio then
            for ch = 0, audio_channel_count - 1 do
                local audio_track = track_resolver_module.resolve_audio_track(timeline_state, ch)
                local audio_cmd = command_module.create(command_type, project_id)
                local clip_id = set_insert_overwrite_parameters(audio_cmd, command_type, audio_track.id, sequence_id, insert_pos, clip_source, ch)
                local result = command_manager_module.execute(audio_cmd)
                assert(result and result.success, string.format("AddClipToTimeline: %s failed: %s", command_type, result and result.error_message or "unknown"))
                table.insert(clip_ids, {clip_id = clip_id, role = "audio", time_offset = 0})
            end
        end

        if #clip_ids > 1 then
            local link_cmd = command_module.create("LinkClips", project_id)
            link_cmd:set_parameter("clips", clip_ids)
            local link_result = command_manager_module.execute(link_cmd)
            assert(link_result and link_result.success, string.format("AddClipToTimeline: LinkClips failed: %s", link_result and link_result.error_message or "unknown"))
        end

        command_manager_module.end_undo_group()

        return {success = true}
    end

    return {
        executor = command_executors["AddClipToTimeline"]
    }
end

return M
