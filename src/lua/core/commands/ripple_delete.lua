local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["RippleDelete"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing RippleDelete command")
        end

        local track_id = command:get_parameter("track_id")
        local gap_start_rat = command:get_parameter("gap_start")
        local gap_duration_rat = command:get_parameter("gap_duration")
        local sequence_id = command:get_parameter("sequence_id")

        -- Validate Rational inputs
        if not track_id then
            print("WARNING: RippleDelete: Missing track_id")
            return false
        end
        
        if type(gap_start_rat) == "number" or type(gap_duration_rat) == "number" then
            error("RippleDelete: gap parameters must be Rational objects, not numbers.")
        end
        
        -- Hydrate from table if needed (e.g. from JSON)
        if type(gap_start_rat) == "table" and gap_start_rat.frames and not getmetatable(gap_start_rat) then
            gap_start_rat = Rational.new(gap_start_rat.frames, gap_start_rat.fps_numerator, gap_start_rat.fps_denominator)
        end
        if type(gap_duration_rat) == "table" and gap_duration_rat.frames and not getmetatable(gap_duration_rat) then
            gap_duration_rat = Rational.new(gap_duration_rat.frames, gap_duration_rat.fps_numerator, gap_duration_rat.fps_denominator)
        end
        
        if not gap_start_rat or not gap_start_rat.frames then
            error("RippleDelete: Invalid gap_start (missing frames)")
        end
        
        if not gap_duration_rat or not gap_duration_rat.frames or gap_duration_rat.frames <= 0 then
            error("RippleDelete: Invalid gap_duration (must be positive Rational)")
        end

        if not sequence_id or sequence_id == "" then
            local seq_query = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
            if seq_query then
                seq_query:bind_value(1, track_id)
                if seq_query:exec() and seq_query:next() then
                    sequence_id = seq_query:value(0)
                end
                seq_query:finalize()
            end
        end

        if not sequence_id or sequence_id == "" then
            print("WARNING: RippleDelete: Unable to determine sequence for track " .. tostring(track_id))
            return false
        end

        local gap_end_rat = gap_start_rat + gap_duration_rat

        -- Ensure global gap is clear (V5: using frames)
        local function ensure_global_gap_is_clear()
            -- We need to check if any clip overlaps the gap interval in FRAME space.
            -- Since all clips in a sequence share the sequence FPS for positioning (timeline_start_frame),
            -- we can compare frames directly if we assume normalization.
            -- However, strict comparison requires Rational comparison.
            
            local gap_query = db:prepare([[
                SELECT id, track_id, timeline_start_frame, duration_frames, fps_numerator, fps_denominator
                FROM clips
                WHERE owner_sequence_id = ?
            ]])
            
            if not gap_query then
                print("ERROR: RippleDelete: Failed to prepare gap validation query")
                return false
            end
            gap_query:bind_value(1, sequence_id)

            local blocking_clips = {}
            if gap_query:exec() then
                while gap_query:next() do
                    local c_start_frame = gap_query:value(2)
                    local c_dur_frame = gap_query:value(3)
                    local c_fps_num = gap_query:value(4)
                    local c_fps_den = gap_query:value(5)
                    
                    local c_start = Rational.new(c_start_frame, c_fps_num, c_fps_den)
                    local c_end = c_start + Rational.new(c_dur_frame, c_fps_num, c_fps_den)
                    
                    -- Check overlap: NOT (end <= gap_start OR start >= gap_end)
                    -- Equivalent to: end > gap_start AND start < gap_end
                    if c_end > gap_start_rat and c_start < gap_end_rat then
                         table.insert(blocking_clips, {
                            clip_id = gap_query:value(0),
                            track_id = gap_query:value(1),
                            start = c_start,
                            end_time = c_end
                        })
                    end
                end
            end
            gap_query:finalize()

            if #blocking_clips > 0 then
                local messages = {}
                for index, info in ipairs(blocking_clips) do
                    messages[index] = string.format(
                        "clip %s on track %s (%s–%s)",
                        tostring(info.clip_id),
                        tostring(info.track_id),
                        tostring(info.start),
                        tostring(info.end_time)
                    )
                end
                print("WARNING: RippleDelete blocked because the gap is not clear across all tracks: " .. table.concat(messages, "; "))
                return false
            end

            return true
        end

        if not ensure_global_gap_is_clear() then
            return false
        end

        -- Identify clips to move (start >= gap_end)
        -- Optimization: Do this in Lua to handle Rational comparison robustly
        local moved_clips = {}
        local query = db:prepare([[
            SELECT id, timeline_start_frame, track_id, fps_numerator, fps_denominator
            FROM clips
            WHERE owner_sequence_id = ?
        ]])
        
        if not query then
            print("ERROR: RippleDelete: Failed to prepare clip query")
            return false
        end
        query:bind_value(1, sequence_id)

        local clip_ids = {}
        if query:exec() then
            while query:next() do
                local c_start_frame = query:value(1)
                local c_fps_num = query:value(3)
                local c_fps_den = query:value(4)
                local c_start = Rational.new(c_start_frame, c_fps_num, c_fps_den)
                
                if c_start >= gap_end_rat then
                    table.insert(clip_ids, {
                        id = query:value(0),
                        start_rat = c_start,
                        track_id = query:value(2)
                    })
                end
            end
        end
        query:finalize()

        if dry_run then
            return true, {
                track_id = track_id,
                gap_start = gap_start_rat,
                gap_duration = gap_duration_rat,
                clip_count = #clip_ids
            }
        end

        for _, info in ipairs(clip_ids) do
            local clip = Clip.load(info.id, db)
            if not clip then
                print(string.format("WARNING: RippleDelete: Clip %s not found", tostring(info.id)))
                return false
            end

            local original_start = clip.timeline_start
            
            -- Move clip: new_start = current_start - gap_duration
            local new_start = clip.timeline_start - gap_duration_rat
            
            -- Clamp to 0 if something went wrong, though validation above should prevent this
            if new_start.frames < 0 then
                new_start = Rational.new(0, new_start.fps_numerator, new_start.fps_denominator)
            end
            
            clip.timeline_start = new_start

            local saved = clip:save(db, {skip_occlusion = true})
            if not saved then
                print(string.format("ERROR: RippleDelete: Failed to save clip %s", tostring(info.id)))
                return false
            end
            
            local update_payload = command_helper.clip_update_payload(clip, sequence_id)
            if update_payload then
                command_helper.add_update_mutation(command, update_payload.track_sequence_id, update_payload)
            end

            table.insert(moved_clips, {
                clip_id = info.id,
                original_start = original_start, -- Rational
                track_id = info.track_id,
            })
        end

        command:set_parameter("ripple_track_id", track_id)
        command:set_parameter("ripple_gap_start", gap_start_rat)
        command:set_parameter("ripple_sequence_id", sequence_id)
        command:set_parameter("ripple_gap_duration", gap_duration_rat)
        command:set_parameter("ripple_moved_clips", moved_clips)

        print(string.format("✅ Ripple deleted gap on track %s (moved %d clip(s) across sequence %s)", tostring(track_id), #moved_clips, tostring(sequence_id)))
        return true
    end

    command_undoers["RippleDelete"] = function(command)
        local moved_clips = command:get_parameter("ripple_moved_clips")
        local sequence_id = command:get_parameter("ripple_sequence_id")
        
        if not moved_clips or #moved_clips == 0 then
            return true
        end

        -- Re-hydrate Rationals if they came back as tables
        local function restore_rat(val)
            if type(val) == "table" and val.frames then
                return Rational.new(val.frames, val.fps_numerator, val.fps_denominator)
            end
            return val
        end

        for _, info in ipairs(moved_clips) do
            local clip = Clip.load(info.clip_id, db)
            if clip then
                local restored_start = restore_rat(info.original_start)
                clip.timeline_start = restored_start
                
                local saved = clip:save(db, {skip_occlusion = true})
                if not saved then
                    print(string.format("WARNING: RippleDelete undo: Failed to restore clip %s", tostring(info.clip_id)))
                else
                    local update_payload = command_helper.clip_update_payload(clip, sequence_id)
                    if update_payload then
                        command_helper.add_update_mutation(command, update_payload.track_sequence_id, update_payload)
                    end
                end
            end
        end

        print("✅ Undo RippleDelete: Restored clip positions")
        return true
    end
    
    command_executors["UndoRippleDelete"] = command_undoers["RippleDelete"]

    return {
        executor = command_executors["RippleDelete"],
        undoer = command_undoers["RippleDelete"]
    }
end

return M