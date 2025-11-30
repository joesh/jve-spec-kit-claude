local M = {}
local Clip = require('models.clip')
local Sequence = require('models.sequence') -- Added
local Rational = require("core.rational") -- Added

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["CreateClip"] = function(command)
        print("Executing CreateClip command")

        local track_id = command:get_parameter("track_id")
        local media_id = command:get_parameter("media_id")
        local sequence_id = command:get_parameter("sequence_id") -- Fetched sequence_id
        
        -- Load sequence to get its FPS
        local sequence = Sequence.load(sequence_id, db)
        if not sequence then
            print(string.format("ERROR: CreateClip: Sequence %s not found.", tostring(sequence_id)))
            return false
        end
        local fps_num = sequence.frame_rate.fps_numerator
        local fps_den = sequence.frame_rate.fps_denominator

        -- Get Rational inputs if available
        local p_start = command:get_parameter("start_value") or command:get_parameter("timeline_start")
        local p_dur = command:get_parameter("duration")
        local p_sin = command:get_parameter("source_in")
        local p_sout = command:get_parameter("source_out")

        -- Get raw frame values from command parameters, defaulting to 0 for start/in
        local raw_timeline_start_frame = (p_start and p_start.frames) or command:get_parameter("timeline_start_frame") or 0
        local raw_duration_frames = (p_dur and p_dur.frames) or command:get_parameter("duration_frames")
        local raw_source_in_frame = (p_sin and p_sin.frames) or command:get_parameter("source_in_frame") or 0
        local raw_source_out_frame = (p_sout and p_sout.frames) or command:get_parameter("source_out_frame")
        local master_clip_id = command:get_parameter("master_clip_id")
        local project_id_param = command:get_parameter("project_id")

        local master_clip = nil
        local copied_properties = {}
        if master_clip_id and master_clip_id ~= "" then
            master_clip = Clip.load_optional(master_clip_id, db)
            if not master_clip then
                print(string.format("WARNING: CreateClip: Master clip %s not found; falling back to media only", tostring(master_clip_id)))
                master_clip_id = nil
            end
        end

        if master_clip and (not media_id or media_id == "") then
            media_id = master_clip.media_id
        end

        if not track_id or track_id == "" or not media_id or media_id == "" then
            print("WARNING: CreateClip: Missing required parameters (track_id or media_id)")
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
            print("WARNING: CreateClip: Missing or invalid duration/source range (after master clip resolution)")
            return false
        end
                
        -- Create Rational objects for clip properties
        local timeline_start_rational = Rational.new(raw_timeline_start_frame, fps_num, fps_den)
        local duration_rational = Rational.new(raw_duration_frames, fps_num, fps_den)
        local source_in_rational = Rational.new(raw_source_in_frame, fps_num, fps_den)
        local source_out_rational = Rational.new(raw_source_out_frame, fps_num, fps_den)

        local clip = Clip.create("Timeline Clip", media_id, {
            project_id = project_id_param or (master_clip and master_clip.project_id),
            track_id = track_id,
            owner_sequence_id = sequence_id, -- Use the fetched sequence_id
            parent_clip_id = master_clip_id,
            source_sequence_id = master_clip and master_clip.source_sequence_id,
            
            -- Pass Rational objects
            timeline_start = timeline_start_rational,
            duration = duration_rational,
            source_in = source_in_rational,
            source_out = source_out_rational,
            
            -- Explicitly pass rate to override defaults
            rate_num = fps_num,
            rate_den = fps_den,
            
            enabled = true,
            offline = master_clip and master_clip.offline,
        })

        command:set_parameter("clip_id", clip.id)
        if master_clip_id and master_clip_id ~= "" then
            command:set_parameter("master_clip_id", master_clip_id)
        end
        if project_id_param then
            command:set_parameter("project_id", project_id_param)
        elseif master_clip and master_clip.project_id then
            command:set_parameter("project_id", master_clip.project_id)
        end

        if clip:save(db) then
            print(string.format("Created clip with ID: %s on track %s at %s", clip.id, track_id, tostring(timeline_start_rational)))
            return true
        else
            print("WARNING: Failed to save clip")
            return false
        end
    end

    return {
        executor = command_executors["CreateClip"]
    }
end

return M
