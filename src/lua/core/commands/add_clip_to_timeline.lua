--- Add master clip to timeline with single-undo multi-channel insertion
--
-- Responsibilities:
-- - Add master clip to timeline at playhead position
-- - Handle Insert and Overwrite modes
-- - Resolve track selection (video track 0, audio tracks 0..N)
-- - Materialize clip data for insertion (video + audio payloads)
-- - Group all channel insertions into single undo group (single undo action)
-- - Compose primitive Insert/Overwrite/LinkClips commands
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
local insert_selected_clip_into_timeline = require("core.clip_insertion")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["AddClipToTimeline"] = function(command)
        local this_func_label = "AddClipToTimeline"

        -- Extract parameters
        local clip = command:get_parameter("clip")
        local timeline_state_module = command:get_parameter("timeline_state")
        local sequence_id = command:get_parameter("sequence_id")
        local project_id = command:get_parameter("project_id") or command.project_id
        local insert_pos = command:get_parameter("insert_pos")
        local command_type = command:get_parameter("command_type")
        local advance_playhead = command:get_parameter("advance_playhead")

        -- Validate required parameters
        assert(clip, this_func_label .. ": no clip provided")
        assert(timeline_state_module, this_func_label .. ": timeline state not available")
        assert(sequence_id, this_func_label .. ": missing sequence_id")
        assert(project_id, this_func_label .. ": missing project_id")
        assert(insert_pos, this_func_label .. ": missing insert position")
        assert(command_type == "Insert" or command_type == "Overwrite", this_func_label .. ": unsupported command_type")

        -- Extract media data from clip
        local media = assert(clip.media or (clip.media_id and command:get_parameter("media_lookup") and command:get_parameter("media_lookup")[clip.media_id]), this_func_label .. ": missing media")
        local media_id = assert(clip.media_id or media.id, this_func_label .. ": missing media_id")
        local source_in = assert(clip.source_in, this_func_label .. ": missing source_in")
        local source_out = assert(clip.source_out or clip.duration or media.duration, this_func_label .. ": missing source_out")
        local duration = source_out - source_in
        assert(duration.frames and duration.frames > 0, this_func_label .. ": invalid duration")

        local payload_project_id = assert(clip.project_id or project_id, this_func_label .. ": missing clip project_id")

        -- Helper functions for media inspection
        local function clip_has_video()
            local width = assert(clip.width or media.width, this_func_label .. ": missing video width")
            local height = assert(clip.height or media.height, this_func_label .. ": missing video height")
            return width > 0 and height > 0
        end

        local function clip_audio_channel_count()
            local channels = assert(clip.audio_channels or media.audio_channels, this_func_label .. ": missing audio channel count")
            return assert(tonumber(channels), this_func_label .. ": audio channel count must be a number")
        end

        local function clip_has_audio()
            return clip_audio_channel_count() > 0
        end

        -- Create selected_clip object with video and audio payload methods
        local selected_clip = {
            video = {
                role = "video",
                media_id = media_id,
                master_clip_id = clip.clip_id,
                project_id = payload_project_id,
                duration = duration,
                source_in = source_in,
                source_out = source_out,
                clip_name = clip.name,
                advance_playhead = advance_playhead
            }
        }

        function selected_clip:has_video()
            return clip_has_video()
        end

        function selected_clip:has_audio()
            return clip_has_audio()
        end

        function selected_clip:audio_channel_count()
            return clip_audio_channel_count()
        end

        function selected_clip:audio(ch)
            assert(ch ~= nil, this_func_label .. ": missing audio channel index")
            return {
                role = "audio",
                media_id = media_id,
                master_clip_id = clip.clip_id,
                project_id = payload_project_id,
                duration = duration,
                source_in = source_in,
                source_out = source_out,
                clip_name = clip.name,
                advance_playhead = advance_playhead,
                channel = ch
            }
        end

        -- Track resolution logic
        local function sort_tracks(tracks)
            table.sort(tracks, function(a, b)
                local a_index = a.track_index or 0
                local b_index = b.track_index or 0
                return a_index < b_index
            end)
        end

        local function target_video_track(_, index)
            local tracks = assert(timeline_state_module.get_video_tracks and timeline_state_module.get_video_tracks(), this_func_label .. ": missing video tracks")
            sort_tracks(tracks)
            local track = tracks[index + 1]
            assert(track and track.id, string.format(this_func_label .. ": missing video track %d", index))
            return track
        end

        local function target_audio_track(_, index)
            local tracks = assert(timeline_state_module.get_audio_tracks and timeline_state_module.get_audio_tracks(), this_func_label .. ": missing audio tracks")
            sort_tracks(tracks)
            local track = tracks[index + 1]
            assert(track and track.id, string.format(this_func_label .. ": missing audio track %d", index))
            return track
        end

        -- Track created clip IDs for linking
        local clip_ids = {}
        local time_param = (command_type == "Overwrite") and "overwrite_time" or "insert_time"
        local command_manager = require("core.command_manager")
        local Command = require("command")

        local function insert_clip(_, payload, track, pos)
            local clip_id = uuid.generate()

            -- Build parameters for Insert/Overwrite command
            local params = {
                sequence_id = sequence_id,
                track_id = assert(track and track.id, this_func_label .. ": missing track id"),
                master_clip_id = payload.master_clip_id,
                duration = assert(payload.duration, this_func_label .. ": missing payload duration"),
                source_in = assert(payload.source_in, this_func_label .. ": missing payload source_in"),
                source_out = assert(payload.source_out, this_func_label .. ": missing payload source_out"),
                project_id = payload_project_id,
                clip_id = clip_id,
                [time_param] = assert(pos, this_func_label .. ": missing insert position")
            }

            if payload.media_id then
                params.media_id = payload.media_id
            end

            if payload.clip_name then
                params.clip_name = payload.clip_name
            end

            if payload.advance_playhead then
                params.advance_playhead = true
            end

            -- Execute Insert/Overwrite command (within undo group)
            local insert_cmd = Command.create(command_type, project_id)
            for k, v in pairs(params) do
                insert_cmd:set_parameter(k, v)
            end

            local result = command_manager.execute(insert_cmd)
            assert(result and result.success, string.format(
                this_func_label .. ": %s command failed: %s",
                command_type,
                result and result.error_message or "unknown error"
            ))

            local clip_info = {clip_id = clip_id, role = payload.role, time_offset = 0}
            table.insert(clip_ids, clip_info)
            return clip_info
        end

        -- Create sequence object
        local sequence = {
            target_video_track = target_video_track,
            target_audio_track = target_audio_track,
            insert_clip = insert_clip
        }

        -- Determine which clips need to be created (video + audio channels)
        local has_video = clip_has_video()
        local has_audio = clip_has_audio()
        local audio_channel_count = has_audio and clip_audio_channel_count() or 0

        -- Begin undo group for atomic multi-channel insertion
        command_manager.begin_undo_group(string.format("Add %s to timeline", clip.name or "clip"))

        -- Execute Insert/Overwrite commands for all channels
        if has_video then
            local track = target_video_track(nil, 0)
            insert_clip(nil, selected_clip.video, track, insert_pos)
        end

        if has_audio then
            for ch = 0, audio_channel_count - 1 do
                local track = target_audio_track(nil, ch)
                insert_clip(nil, selected_clip:audio(ch), track, insert_pos)
            end
        end

        -- Link clips if multiple channels were inserted
        if #clip_ids > 1 then
            local link_cmd = Command.create("LinkClips", project_id)
            link_cmd:set_parameter("clips", clip_ids)

            local link_result = command_manager.execute(link_cmd)
            assert(link_result and link_result.success, string.format(
                this_func_label .. ": LinkClips failed: %s",
                link_result and link_result.error_message or "unknown error"
            ))
        end

        -- End undo group (commits or rolls back on failure)
        command_manager.end_undo_group()

        return {success = true}
    end

    return {
        executor = command_executors["AddClipToTimeline"]
    }
end

return M
