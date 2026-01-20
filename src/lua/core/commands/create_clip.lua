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
-- Size: ~149 LOC
-- Volatility: unknown
--
-- @file create_clip.lua
local M = {}
local Clip = require('models.clip')
local Sequence = require('models.sequence') -- Added
local Rational = require("core.rational") -- Added
local insert_selected_clip_into_timeline = require("core.clip_insertion")


local SPEC = {
    requires_any = {
        {"media_id", "master_clip_id"},
    },
    args = {
        clip_id = {},
        duration = {},
        duration_frames = {},
        master_clip_id = {},
        media_id = {},
        project_id = { required = true },
        sequence_id = {},
        source_in = {},
        source_in_frame = { kind = "number", default = 0 },
        source_out = {},
        source_out_frame = {},
        start_value = {},
        timeline_start = {},
        timeline_start_frame = { kind = "number", default = 0 },
        track_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["CreateClip"] = function(command)
        local args = command:get_all_parameters()
        print("Executing CreateClip command")

        local track_id = args.track_id
        local media_id = args.media_id
        local sequence_id = args.sequence_id -- Fetched sequence_id
        
        -- Load sequence to get its FPS
        local sequence = Sequence.load(sequence_id)
        if not sequence then
            print(string.format("ERROR: CreateClip: Sequence %s not found.", tostring(sequence_id)))
            return false
        end
        local fps_num = sequence.frame_rate.fps_numerator
        local fps_den = sequence.frame_rate.fps_denominator

        -- Helper to safely extract frame count from Rational or Number
        local function extract_frames(param)
            if type(param) == "table" and param.frames then
                return param.frames
            elseif type(param) == "number" then
                return param
            end
            return nil
        end

        -- Get Rational inputs if available
        local p_start = args.start_value or args.timeline_start




        -- Get raw frame values from command parameters, defaulting to 0 for start/in
        local raw_timeline_start_frame = extract_frames(p_start) or args.timeline_start_frame
        local raw_duration_frames = extract_frames(args.duration) or args.duration_frames
        local raw_source_in_frame = extract_frames(args.source_in) or args.source_in_frame
        local raw_source_out_frame = extract_frames(args.source_out) or args.source_out_frame
        local master_clip_id = args.master_clip_id


        local master_clip = nil
        local copied_properties = {}
        if master_clip_id and master_clip_id ~= "" then
            master_clip = Clip.load_optional(master_clip_id)
            if not master_clip then
                print(string.format("WARNING: CreateClip: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
                master_clip_id = nil
            end
        end

        if master_clip and (not media_id or media_id == "") then
            media_id = master_clip.media_id
        end

        if not media_id or media_id == "" then
            set_last_error("CreateClip: Missing media_id (and no usable master_clip_id)")
            return false
        end

        -- Determine duration and source range, prioritizing master clip if available
        if master_clip then
            if not raw_duration_frames or raw_duration_frames <= 0 then
                raw_duration_frames = master_clip.duration.frames
            end
            if not raw_source_out_frame or raw_source_out_frame <= raw_source_in_frame then
                raw_source_in_frame = master_clip.source_in.frames
                raw_source_out_frame = master_clip.source_out.frames
            end
        end
        
        -- Fallback: if duration known but source_out missing, calculate it
        if (raw_duration_frames and raw_duration_frames > 0) and (not raw_source_out_frame or raw_source_out_frame <= raw_source_in_frame) then
            raw_source_out_frame = raw_source_in_frame + raw_duration_frames
        end

        if not raw_duration_frames or raw_duration_frames <= 0 or not raw_source_out_frame or raw_source_out_frame <= raw_source_in_frame then
            set_last_error("CreateClip: Missing or invalid duration/source range (after master clip resolution)")
            return false
        end
                
        -- Create Rational objects for clip properties
        local timeline_start_rational = Rational.new(raw_timeline_start_frame, fps_num, fps_den)
        local duration_rational = Rational.new(raw_duration_frames, fps_num, fps_den)
        local source_in_rational = Rational.new(raw_source_in_frame, fps_num, fps_den)
        local source_out_rational = Rational.new(raw_source_out_frame, fps_num, fps_den)

        local clip_payload = {
            role = "video",
            media_id = media_id,
            master_clip_id = master_clip_id,
            project_id = args.project_id or (master_clip and master_clip.project_id),
            duration = duration_rational,
            source_in = source_in_rational,
            source_out = source_out_rational,
            clip_name = "Timeline Clip"
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
            assert(index == 0, "CreateClip: unexpected video track index")
            return {id = track_id}
        end

        local function target_audio_track(_, index)
            assert(false, "CreateClip: unexpected audio track index " .. tostring(index))
        end

        local function insert_clip(_, payload, target_track, pos)
            local insert_time = assert(pos, "CreateClip: missing insert position")
            local insert_track_id = assert(target_track and target_track.id, "CreateClip: missing target track id")
            local clip = Clip.create(payload.clip_name or "Timeline Clip", payload.media_id, {
                project_id = payload.project_id,
                track_id = insert_track_id,
                owner_sequence_id = sequence_id,
                parent_clip_id = payload.master_clip_id,
                source_sequence_id = master_clip and master_clip.source_sequence_id,
                timeline_start = insert_time,
                duration = payload.duration,
                source_in = payload.source_in,
                source_out = payload.source_out,
                fps_numerator = fps_num,
                fps_denominator = fps_den,
                enabled = true,
                offline = master_clip and master_clip.offline,
            })

            command:set_parameter("clip_id", clip.id)
            if payload.master_clip_id and payload.master_clip_id ~= "" then
                command:set_parameter("master_clip_id", payload.master_clip_id)
            end
            if args.project_id then
                command:set_parameter("project_id", args.project_id)
            elseif master_clip and master_clip.project_id then
                command:set_parameter("project_id", master_clip.project_id)
            end

            assert(clip:save(), "CreateClip: failed to save clip")
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

        print(string.format("Created clip with ID: %s on track %s at %s", args.clip_id, track_id, tostring(timeline_start_rational)))
        return true
    end

    return {
        executor = command_executors["CreateClip"],
        spec = SPEC,
    }
end

return M
