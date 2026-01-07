local M = {}

local uuid_module            = require("uuid")
local command_manager_module = require("core.command_manager")
local command_module         = require("command")
local clip_media_module      = require("core.utils.clip_media")
local track_resolver_module  = require("core.utils.track_resolver")

local function begin_undo_group(label)
    command_manager_module.begin_undo_group(label)
end

local function end_undo_group()
    command_manager_module.end_undo_group()
end

local function execute_insert_clip(track_id, position, clip_source, channel, sequence_id, project_id)
    local clip_id = uuid_module.generate()

    local cmd = command_module.create("Insert", project_id)
    cmd:set_parameter("sequence_id", sequence_id)
    cmd:set_parameter("track_id", track_id)
    cmd:set_parameter("master_clip_id", clip_source.master_clip_id)
    cmd:set_parameter("duration", clip_source.duration)
    cmd:set_parameter("source_in", clip_source.source_in)
    cmd:set_parameter("source_out", clip_source.source_out)
    cmd:set_parameter("project_id", clip_source.project_id)
    cmd:set_parameter("clip_id", clip_id)
    cmd:set_parameter("insert_time", position)
    if clip_source.media_id then cmd:set_parameter("media_id", clip_source.media_id) end
    if clip_source.clip_name then cmd:set_parameter("clip_name", clip_source.clip_name) end
    if clip_source.advance_playhead then cmd:set_parameter("advance_playhead", true) end
    if channel ~= nil then cmd:set_parameter("channel", channel) end

    local result = command_manager_module.execute(cmd)
    assert(result and result.success, string.format("Insert failed: %s", result and result.error_message or "unknown"))

    return clip_id
end

local function execute_overwrite_clip(track_id, position, clip_source, channel, sequence_id, project_id)
    local clip_id = uuid_module.generate()

    local cmd = command_module.create("Overwrite", project_id)
    cmd:set_parameter("sequence_id", sequence_id)
    cmd:set_parameter("track_id", track_id)
    cmd:set_parameter("master_clip_id", clip_source.master_clip_id)
    cmd:set_parameter("duration", clip_source.duration)
    cmd:set_parameter("source_in", clip_source.source_in)
    cmd:set_parameter("source_out", clip_source.source_out)
    cmd:set_parameter("project_id", clip_source.project_id)
    cmd:set_parameter("clip_id", clip_id)
    cmd:set_parameter("overwrite_time", position)
    if clip_source.media_id then cmd:set_parameter("media_id", clip_source.media_id) end
    if clip_source.clip_name then cmd:set_parameter("clip_name", clip_source.clip_name) end
    if clip_source.advance_playhead then cmd:set_parameter("advance_playhead", true) end
    if channel ~= nil then cmd:set_parameter("channel", channel) end

    local result = command_manager_module.execute(cmd)
    assert(result and result.success, string.format("Overwrite failed: %s", result and result.error_message or "unknown"))

    return clip_id
end

local function execute_link_clips(clip_ids, project_id)
    if #clip_ids <= 1 then return end

    local cmd = command_module.create("LinkClips", project_id)
    cmd:set_parameter("clips", clip_ids)

    local result = command_manager_module.execute(cmd)
    assert(result and result.success, string.format("LinkClips failed: %s", result and result.error_message or "unknown"))
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddClipToTimeline"] = function(command)
        local clip = assert(command:get_parameter("clip"))
        local timeline_state = assert(command:get_parameter("timeline_state"))
        local sequence_id = assert(command:get_parameter("sequence_id"))
        local project_id = assert(command:get_parameter("project_id") or command.project_id)
        local position = assert(command:get_parameter("insert_pos"))
        local edit_type = assert(command:get_parameter("command_type"))
        assert(edit_type == "Insert" or edit_type == "Overwrite")

        local media_lookup = command:get_parameter("media_lookup")
        local media = assert(clip.media or (clip.media_id and media_lookup and media_lookup[clip.media_id]))
        local source_in = assert(clip.source_in)
        local source_out = assert(clip.source_out or clip.duration or media.duration)
        local duration = source_out - source_in
        assert(duration.frames and duration.frames > 0)

        local has_video = clip_media_module.has_video(clip, media)
        local has_audio = clip_media_module.has_audio(clip, media)
        local audio_channels = has_audio and clip_media_module.audio_channel_count(clip, media) or 0

        local clip_source = {
            media_id = clip.media_id or media.id,
            master_clip_id = clip.clip_id,
            project_id = clip.project_id or project_id,
            duration = duration,
            source_in = source_in,
            source_out = source_out,
            clip_name = clip.name,
            advance_playhead = command:get_parameter("advance_playhead")
        }

        local inserted_clips = {}

        begin_undo_group(string.format("Add %s to timeline", clip.name or "clip"))

        if edit_type == "Insert" then
            if has_video then
                table.insert(inserted_clips, {clip_id = execute_insert_clip(track_resolver_module.resolve_video_track(timeline_state, 0).id, position, clip_source, nil, sequence_id, project_id), role = "video", time_offset = 0})
            end
            if has_audio then
                for ch = 0, audio_channels - 1 do
                    table.insert(inserted_clips, {clip_id = execute_insert_clip(track_resolver_module.resolve_audio_track(timeline_state, ch).id, position, clip_source, ch, sequence_id, project_id), role = "audio", time_offset = 0})
                end
            end
        else
            if has_video then
                table.insert(inserted_clips, {clip_id = execute_overwrite_clip(track_resolver_module.resolve_video_track(timeline_state, 0).id, position, clip_source, nil, sequence_id, project_id), role = "video", time_offset = 0})
            end
            if has_audio then
                for ch = 0, audio_channels - 1 do
                    table.insert(inserted_clips, {clip_id = execute_overwrite_clip(track_resolver_module.resolve_audio_track(timeline_state, ch).id, position, clip_source, ch, sequence_id, project_id), role = "audio", time_offset = 0})
                end
            end
        end

        execute_link_clips(inserted_clips, project_id)

        end_undo_group()

        return {success = true}
    end

    return {
        executor = command_executors["AddClipToTimeline"]
    }
end

return M
