local M = {}

local uuid_module            = require("uuid")
local command_manager_module = require("core.command_manager")
local command_module         = require("command")
local clip_media_module      = require("core.utils.clip_media")
local track_resolver_module  = require("core.utils.track_resolver")
local begin_undo_group
local end_undo_group
local execute_insert_clip
local execute_overwrite_clip
local execute_link_clips


local SPEC = {
    args = {
        advance_playhead = { kind = "boolean" },
        clip = { required = true },
        command_type = { required = true },
        insert_pos = { required = true },
        media_lookup = {},
        project_id = { required = true },
        sequence_id = { required = true },
        timeline_state = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddClipToTimeline"] = function(command)
        local args = command:get_all_parameters()
        local clip = assert(args.clip)
        local timeline_state = assert(args.timeline_state)
        local sequence_id = assert(args.sequence_id)
        local project_id = assert(args.project_id or command.project_id)
        local position = assert(args.insert_pos)
        local edit_type = assert(args.command_type)
        assert(edit_type == "Insert" or edit_type == "Overwrite")


        local media = assert(clip.media or (clip.media_id and args.media_lookup and args.media_lookup[clip.media_id]))
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
            advance_playhead = args.advance_playhead
        }

        local inserted_clips = {}

        begin_undo_group(string.format("Add %s to timeline", clip.name or "clip"))

        if edit_type == "Insert" then
            if has_video then
                local track = track_resolver_module.resolve_video_track(timeline_state, 0)
                local clip_id = execute_insert_clip(track.id, position, clip_source, nil, sequence_id, project_id)
                table.insert(inserted_clips, {clip_id = clip_id, role = "video", time_offset = 0})
            end
            if has_audio then
                for ch = 0, audio_channels - 1 do
                    local track = track_resolver_module.resolve_audio_track(timeline_state, ch)
                    local clip_id = execute_insert_clip(track.id, position, clip_source, ch, sequence_id, project_id)
                    table.insert(inserted_clips, {clip_id = clip_id, role = "audio", time_offset = 0})
                end
            end
        else
            if has_video then
                local track = track_resolver_module.resolve_video_track(timeline_state, 0)
                local clip_id = execute_overwrite_clip(track.id, position, clip_source, nil, sequence_id, project_id)
                table.insert(inserted_clips, {clip_id = clip_id, role = "video", time_offset = 0})
            end
            if has_audio then
                for ch = 0, audio_channels - 1 do
                    local track = track_resolver_module.resolve_audio_track(timeline_state, ch)
                    local clip_id = execute_overwrite_clip(track.id, position, clip_source, ch, sequence_id, project_id)
                    table.insert(inserted_clips, {clip_id = clip_id, role = "audio", time_offset = 0})
                end
            end
        end

        execute_link_clips(inserted_clips, project_id)

        end_undo_group()

        return {success = true}
    end

    return {
        executor = command_executors["AddClipToTimeline"],
        undoer = nil,  -- No undoer - uses begin_undo_group/end_undo_group for composite undo
        spec = SPEC,
    }
end


begin_undo_group = function(label)
    command_manager_module.begin_undo_group(label)
end

end_undo_group = function()
    command_manager_module.end_undo_group()
end

execute_insert_clip = function(track_id, position, clip_source, channel, sequence_id, project_id)
    local clip_id = uuid_module.generate()

    local params = {
        sequence_id = sequence_id,
        track_id = track_id,
        master_clip_id = clip_source.master_clip_id,
        duration = clip_source.duration,
        source_in = clip_source.source_in,
        source_out = clip_source.source_out,
        project_id = clip_source.project_id,
        clip_id = clip_id,
        insert_time = position,
    }

    if clip_source.media_id then params.media_id = clip_source.media_id end
    if clip_source.clip_name then params.clip_name = clip_source.clip_name end
    if clip_source.advance_playhead then params.advance_playhead = true end
    if channel ~= nil then params.channel = channel end

    local result = command_manager_module.execute("Insert", params)
    assert(result and result.success, string.format("Insert failed: %s", result and result.error_message or "unknown"))

    return clip_id
end

execute_overwrite_clip = function(track_id, position, clip_source, channel, sequence_id, project_id)
    local clip_id = uuid_module.generate()

    local params = {
        sequence_id = sequence_id,
        track_id = track_id,
        master_clip_id = clip_source.master_clip_id,
        duration = clip_source.duration,
        source_in = clip_source.source_in,
        source_out = clip_source.source_out,
        project_id = clip_source.project_id,
        clip_id = clip_id,
        overwrite_time = position,
    }

    if clip_source.media_id then params.media_id = clip_source.media_id end
    if clip_source.clip_name then params.clip_name = clip_source.clip_name end
    if clip_source.advance_playhead then params.advance_playhead = true end
    if channel ~= nil then params.channel = channel end

    local result = command_manager_module.execute("Overwrite", params)
    assert(result and result.success, string.format("Overwrite failed: %s", result and result.error_message or "unknown"))

    return clip_id
end

execute_link_clips = function(clip_ids, project_id)
    if #clip_ids <= 1 then return end

    local result = command_manager_module.execute("LinkClips", {
        clips = clip_ids,
        project_id = project_id,
    })
    assert(result and result.success, string.format("LinkClips failed: %s", result and result.error_message or "unknown"))
end

return M
