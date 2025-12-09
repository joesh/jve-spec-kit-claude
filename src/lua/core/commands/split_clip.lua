local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local Rational = require("core.rational")

function M.register(command_executors, command_undoers, db, set_last_error)
    local function to_rational(val, context_clip)
        if type(val) == "table" and val.frames then return val end
        local rate = (context_clip and context_clip.rate) or {fps_numerator=30, fps_denominator=1}
        return Rational.new(val or 0, rate.fps_numerator, rate.fps_denominator)
    end

    command_executors["SplitClip"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing SplitClip command")
        end

        local clip_id = command:get_parameter("clip_id")
        local split_val_param = command:get_parameter("split_value") or command:get_parameter("split_time")

        if not dry_run then
            print(string.format("  clip_id: %s", tostring(clip_id)))
            print(string.format("  split_value: %s", tostring(split_val_param)))
        end

        if not clip_id or clip_id == "" or not split_val_param then
            print("WARNING: SplitClip: Missing required parameters")
            return false
        end

        local original_clip = Clip.load(clip_id, db)
        if not original_clip or original_clip.id == "" then
            print(string.format("WARNING: SplitClip: Clip not found: %s", clip_id))
            return false
        end

        -- Strict Rational Input: do not accept bare numbers
        local split_rat = Rational.hydrate(split_val_param)
        
        if not split_rat or not split_rat.frames then
            error("SplitClip: Invalid split_value (missing frames)")
        end

        -- Strict Model Access
        local start_rat = original_clip.timeline_start
        if not start_rat then error("SplitClip: Clip missing timeline_start (Rational)") end
        
        local dur_rat = original_clip.duration
        if not dur_rat then error("SplitClip: Clip missing duration (Rational)") end
        
        local end_rat = start_rat + dur_rat

        if split_rat <= start_rat or split_rat >= end_rat then
            print(string.format("WARNING: SplitClip: split_value %s is outside clip bounds [%s, %s]",
                tostring(split_rat), tostring(start_rat), tostring(end_rat)))
            return false
        end

        local mutation_sequence = original_clip.owner_sequence_id or original_clip.track_sequence_id
        if (not mutation_sequence or mutation_sequence == "") and original_clip.track_id then
            mutation_sequence = command_helper.resolve_sequence_for_track(command:get_parameter("sequence_id"), original_clip.track_id)
        end
        if mutation_sequence and (not command:get_parameter("sequence_id") or command:get_parameter("sequence_id") == "") then
            command:set_parameter("sequence_id", mutation_sequence)
        end

        command:set_parameter("track_id", original_clip.track_id)
        command:set_parameter("original_timeline_start", start_rat)
        command:set_parameter("original_duration", dur_rat)
        command:set_parameter("original_source_in", original_clip.source_in)
        command:set_parameter("original_source_out", original_clip.source_out)

        local first_duration = split_rat - start_rat
        local second_duration = dur_rat - first_duration
        local source_in_rat = original_clip.source_in or to_rational(original_clip.source_in_value or 0, original_clip)
        local source_split_point = source_in_rat + first_duration

        local existing_second_clip_id = command:get_parameter("second_clip_id")
        
        local second_clip = Clip.create(original_clip.name, original_clip.media_id, {
            project_id = original_clip.project_id,
            track_id = original_clip.track_id,
            parent_clip_id = original_clip.parent_clip_id,
            owner_sequence_id = original_clip.owner_sequence_id,
            source_sequence_id = original_clip.source_sequence_id,
            timeline_start = split_rat,
            duration = second_duration,
            source_in = source_split_point,
            source_out = original_clip.source_out,
            enabled = original_clip.enabled,
            offline = original_clip.offline,
            rate_num = original_clip.rate.fps_numerator, -- Explicitly pass rate
            rate_den = original_clip.rate.fps_denominator, -- Explicitly pass rate
        })
        
        if existing_second_clip_id then
            second_clip.id = existing_second_clip_id
        end

        if dry_run then
            -- Return simple preview
            return true, {
                first_clip = { clip_id = original_clip.id },
                second_clip = { clip_id = second_clip.id }
            }
        end

        original_clip.duration = first_duration
        original_clip.source_out = source_split_point

        if not original_clip:save(db) then
            print("WARNING: SplitClip: Failed to save modified original clip")
            return false
        end

        local first_update = command_helper.clip_update_payload(original_clip, mutation_sequence)
        if first_update then
            command_helper.add_update_mutation(command, first_update.track_sequence_id or mutation_sequence, first_update)
        end

        if not second_clip:save(db) then
            print("WARNING: SplitClip: Failed to save new clip")
            return false
        end

        local second_insert = command_helper.clip_insert_payload(second_clip, mutation_sequence)
        if second_insert then
            command_helper.add_insert_mutation(command, second_insert.track_sequence_id or mutation_sequence, second_insert)
        end

        command:set_parameter("second_clip_id", second_clip.id)

        print(string.format("Split clip %s at time %s into clips %s and %s",
            clip_id, tostring(split_rat), original_clip.id, second_clip.id))
        return true
    end

    local function perform_split_clip_undo(command)
        print("Executing UndoSplitClip command")

        local clip_id = command:get_parameter("clip_id")
        local track_id = command:get_parameter("track_id")
        local original_timeline_start = command:get_parameter("original_timeline_start")
        local original_duration = command:get_parameter("original_duration")
        local original_source_in = command:get_parameter("original_source_in")
        local original_source_out = command:get_parameter("original_source_out")
        local second_clip_id = command:get_parameter("second_clip_id")
        local mutation_sequence = command:get_parameter("sequence_id")

        if not clip_id or not second_clip_id then
            print("WARNING: UndoSplitClip: Missing required parameters")
            return false
        end

        -- Re-hydrate Rationals if they came back as tables/numbers
        local function restore_rat(val)
            if type(val) == "table" and val.frames then
                return Rational.new(val.frames, val.fps_numerator, val.fps_denominator)
            end
            return val
        end
        original_timeline_start = restore_rat(original_timeline_start)
        original_duration = restore_rat(original_duration)
        original_source_in = restore_rat(original_source_in)
        original_source_out = restore_rat(original_source_out)

        local original_clip = Clip.load(clip_id, db)
        if not original_clip then
            print(string.format("WARNING: UndoSplitClip: Original clip not found: %s", clip_id))
            return false
        end

        local second_clip = Clip.load(second_clip_id, db)
        if not second_clip then
            print(string.format("WARNING: UndoSplitClip: Second clip not found: %s", second_clip_id))
            -- Fallback: try to proceed if original clip is valid, but maybe we can't delete second clip?
            -- If second clip is missing, maybe we just restore first.
        end

        if second_clip then
            if not second_clip:delete(db) then
                print("WARNING: UndoSplitClip: Failed to delete second clip")
                return false
            end
            command_helper.add_delete_mutation(command, mutation_sequence, second_clip_id)
        end

        original_clip.timeline_start = original_timeline_start
        original_clip.duration = original_duration
        original_clip.source_in = original_source_in
        original_clip.source_out = original_source_out

        if not original_clip:save(db) then
            print("WARNING: UndoSplitClip: Failed to save original clip")
            return false
        end

        local restore_update = command_helper.clip_update_payload(original_clip, mutation_sequence)
        if restore_update then
            command_helper.add_update_mutation(command, restore_update.track_sequence_id or mutation_sequence, restore_update)
        end

        print(string.format("Undid split: restored clip %s and deleted clip %s",
            clip_id, second_clip_id))
        return true
    end

    command_undoers["SplitClip"] = perform_split_clip_undo
    command_executors["UndoSplitClip"] = perform_split_clip_undo

    return {
        executor = command_executors["SplitClip"],
        undoer = command_undoers["SplitClip"]
    }
end

return M
