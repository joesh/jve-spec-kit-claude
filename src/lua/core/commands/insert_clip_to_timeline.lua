--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~190 LOC
-- Volatility: unknown
--
-- @file insert_clip_to_timeline.lua
local M = {}
local Clip = require('models.clip')
local Sequence = require('models.sequence')
local Media = require('models.media')
local Rational = require("core.rational")
local command_helper = require("core.command_helper")
local insert_selected_clip_into_timeline = require("core.clip_insertion")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["InsertClipToTimeline"] = function(command)
        print("Executing InsertClipToTimeline command")

        local media_id = command:get_parameter("media_id")
        local track_id = command:get_parameter("track_id")
        local sequence_id = command:get_parameter("sequence_id")
        
        -- Get time parameters, now in frames
        local raw_timeline_start_frame = command:get_parameter("timeline_start_frame") or 0
        local cmd_duration_frames = command:get_parameter("duration_frames")
        local cmd_source_in_frame = command:get_parameter("source_in_frame")
        local cmd_source_out_frame = command:get_parameter("source_out_frame")

        if not sequence_id then
            print("ERROR: InsertClipToTimeline: Missing sequence_id parameter.")
            return false
        end

        local sequence = Sequence.load(sequence_id, db)
        if not sequence then
            print(string.format("ERROR: InsertClipToTimeline: Sequence %s not found.", tostring(sequence_id)))
            return false
        end
        local sequence_fps_num = sequence.frame_rate.fps_numerator
        local sequence_fps_den = sequence.frame_rate.fps_denominator

        local media = Media.load(media_id, db)
        if not media then
            print(string.format("ERROR: InsertClipToTimeline: Media %s not found.", tostring(media_id)))
            return false
        end

        local master_clip_id = command:get_parameter("master_clip_id")
        local project_id_param = command:get_parameter("project_id")
        local master_clip = nil

        if master_clip_id and master_clip_id ~= "" then
            master_clip = Clip.load_optional(master_clip_id, db)
            if not master_clip then
                print(string.format("WARNING: InsertClipToTimeline: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
                master_clip_id = nil
            end
        end

        if master_clip and (not media_id or media_id == "") then
            media_id = master_clip.media_id
        end

        if not track_id or track_id == "" or not media_id or media_id == "" then
            print("WARNING: InsertClipToTimeline: Missing required parameters (track_id or media_id)")
            return false
        end

        -- Initialize Rational properties
        local timeline_start_rational = Rational.new(raw_timeline_start_frame, sequence_fps_num, sequence_fps_den)
        local clip_duration_rational
        local clip_source_in_rational
        local clip_source_out_rational

        -- Determine initial clip duration and source range, prioritizing master clip if available
        if master_clip then
            clip_duration_rational = master_clip.duration:rescale(sequence_fps_num, sequence_fps_den)
            clip_source_in_rational = master_clip.source_in:rescale(sequence_fps_num, sequence_fps_den)
            clip_source_out_rational = master_clip.source_out:rescale(sequence_fps_num, sequence_fps_den)
        else
            -- Use media duration, rescaled to sequence's FPS
            clip_duration_rational = media.duration:rescale(sequence_fps_num, sequence_fps_den)
            clip_source_in_rational = Rational.new(0, media.frame_rate.fps_numerator, media.frame_rate.fps_denominator):rescale(sequence_fps_num, sequence_fps_den)
            clip_source_out_rational = media.duration:rescale(sequence_fps_num, sequence_fps_den)
        end
        
        -- Override with explicit command parameters if provided
        if cmd_duration_frames then
            clip_duration_rational = Rational.new(cmd_duration_frames, sequence_fps_num, sequence_fps_den)
        end
        if cmd_source_in_frame then
            clip_source_in_rational = Rational.new(cmd_source_in_frame, sequence_fps_num, sequence_fps_den)
        end
        if cmd_source_out_frame then
            clip_source_out_rational = Rational.new(cmd_source_out_frame, sequence_fps_num, sequence_fps_den)
        end

        -- Ensure duration is positive (STRICT)
        if clip_duration_rational.frames <= 0 then
            print("ERROR: InsertClipToTimeline: Calculated duration is zero or negative.")
            return false
        end
        
        -- Ensure source_out is greater than source_in
        if clip_source_out_rational.frames <= clip_source_in_rational.frames then
            print("WARNING: InsertClipToTimeline: Calculated source_out is not greater than source_in. Adjusting.")
            clip_source_out_rational = clip_source_in_rational + Rational.new(1, sequence_fps_num, sequence_fps_den)
        end

        local copied_properties = {} -- this might be for master clip properties, need to re-evaluate in audit
        if master_clip then
            copied_properties = command_helper.ensure_copied_properties(command, master_clip_id)
        end

        local clip_payload = {
            role = "video",
            media_id = media_id,
            master_clip_id = master_clip_id,
            project_id = project_id_param or (master_clip and master_clip.project_id),
            duration = clip_duration_rational,
            source_in = clip_source_in_rational,
            source_out = clip_source_out_rational,
            clip_name = "Clip"
        }

        local selected_clip = {
            video = clip_payload
        }

        function selected_clip:has_video()
            return true
        end

        function selected_clip:has_audio()
            return false
        end

        function selected_clip:audio_channel_count()
            return 0
        end

        local function target_video_track(_, index)
            assert(index == 0, "InsertClipToTimeline: unexpected video track index")
            return {id = track_id}
        end

        local function target_audio_track(_, index)
            assert(false, "InsertClipToTimeline: unexpected audio track index " .. tostring(index))
        end

        local function insert_clip(_, payload, target_track, pos)
            local insert_time = assert(pos, "InsertClipToTimeline: missing insert position")
            local insert_track_id = assert(target_track and target_track.id, "InsertClipToTimeline: missing target track id")
            local clip = Clip.create(payload.clip_name or "Clip", payload.media_id, {
                project_id = payload.project_id,
                track_id = insert_track_id,
                owner_sequence_id = sequence_id,
                parent_clip_id = payload.master_clip_id,
                source_sequence_id = master_clip and master_clip.source_sequence_id,
                timeline_start = insert_time,
                duration = payload.duration,
                source_in = payload.source_in,
                source_out = payload.source_out,
                rate_num = sequence_fps_num,
                rate_den = sequence_fps_den,
                enabled = true,
                offline = master_clip and master_clip.offline,
            })

            command:set_parameter("clip_id", clip.id)
            if payload.master_clip_id and payload.master_clip_id ~= "" then
                command:set_parameter("master_clip_id", payload.master_clip_id)
            end
            if project_id_param then
                command:set_parameter("project_id", project_id_param)
            elseif master_clip and master_clip.project_id then
                command:set_parameter("project_id", master_clip.project_id)
            end

            assert(clip:save(db), "InsertClipToTimeline: failed to save clip to timeline")
            if #copied_properties > 0 then
                command_helper.delete_properties_for_clip(clip.id)
                if not command_helper.insert_properties_for_clip(clip.id, copied_properties) then
                    print(string.format("WARNING: InsertClipToTimeline: Failed to copy properties from master clip %s", tostring(master_clip_id)))
                end
            end

            return {id = clip.id, role = payload.role, time_offset = 0}
        end

        local sequence_proxy = {
            target_video_track = target_video_track,
            target_audio_track = target_audio_track,
            insert_clip = insert_clip
        }

        insert_selected_clip_into_timeline({
            selected_clip = selected_clip,
            sequence = sequence_proxy,
            insert_pos = timeline_start_rational
        })

        print(string.format("✅ Inserted clip %s to track %s at %s", command:get_parameter("clip_id"), track_id, tostring(timeline_start_rational)))
        return true
    end

    command_undoers["UndoInsertClipToTimeline"] = function(command)
        print("Executing UndoInsertClipToTimeline command")

        local clip_id = command:get_parameter("clip_id")

        if not clip_id or clip_id == "" then
            print("WARNING: UndoInsertClipToTimeline: Missing clip_id")
            return false
        end

        local clip = Clip.load(clip_id, db)

        if not clip then
            print(string.format("WARNING: UndoInsertClipToTimeline: Clip not found: %s", clip_id))
            return false
        end

        command_helper.delete_properties_for_clip(clip_id)
        if clip:delete(db) then
            print(string.format("✅ Removed clip %s from timeline", clip_id))
            return true
        else
            print("WARNING: Failed to delete clip from timeline")
            return false
        end
    end

    command_executors["UndoInsertClipToTimeline"] = command_undoers["UndoInsertClipToTimeline"]

    return {
        executor = command_executors["InsertClipToTimeline"],
        undoer = command_undoers["UndoInsertClipToTimeline"]
    }
end

return M
