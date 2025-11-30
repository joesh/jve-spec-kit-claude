local M = {}
local Clip = require('models.clip')
local frame_utils = require('core.frame_utils') -- Still used for legacy/migration. Keep for now.
local command_helper = require("core.command_helper")
local Rational = require("core.rational")
local clip_mutator = require("core.clip_mutator")

function M.register(command_executors, command_undoers, db, set_last_error)
    local function record_occlusion_actions(command, sequence_id, actions)
        if not actions or #actions == 0 then return end
        for _, action in ipairs(actions) do
            if action.type == "delete" and action.clip and action.clip.id then
                command_helper.add_delete_mutation(command, sequence_id, action.clip.id)
            elseif action.type == "trim" and action.after then
                local update = command_helper.clip_update_payload(action.after, sequence_id)
                if update then
                    command_helper.add_update_mutation(command, update.track_sequence_id or sequence_id, update)
                end
            elseif action.type == "insert" and action.clip then
                local insert_payload = command_helper.clip_insert_payload(action.clip, sequence_id)
                if insert_payload then
                    command_helper.add_insert_mutation(command, insert_payload.track_sequence_id or sequence_id, insert_payload)
                end
            end
        end
    end

    command_executors["MoveClipToTrack"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing MoveClipToTrack command")
        end

        local clip_id = command:get_parameter("clip_id")
        local target_track_id = command:get_parameter("target_track_id")

        if not clip_id or clip_id == "" then
            print("WARNING: MoveClipToTrack: Missing clip_id")
            return false
        end

        if not target_track_id or target_track_id == "" then
            print("WARNING: MoveClipToTrack: Missing target_track_id")
            return false
        end

        local clip = Clip.load(clip_id, db)

        if not clip then
            print(string.format("WARNING: MoveClipToTrack: Clip %s not found", clip_id))
            return false
        end

        local mutation_sequence = clip.owner_sequence_id or clip.track_sequence_id
        if (not mutation_sequence or mutation_sequence == "") and clip.track_id then
            local seq_lookup = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
            if seq_lookup then
                seq_lookup:bind_value(1, clip.track_id)
                if seq_lookup:exec() and seq_lookup:next() then
                    mutation_sequence = seq_lookup:value(0)
                end
                seq_lookup:finalize()
            end
        end
        if not mutation_sequence or mutation_sequence == "" then
            local target_lookup = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
            if target_lookup then
                target_lookup:bind_value(1, target_track_id)
                if target_lookup:exec() and target_lookup:next() then
                    mutation_sequence = target_lookup:value(0)
                end
                target_lookup:finalize()
            end
        end
        if not mutation_sequence or mutation_sequence == "" then
            print("WARNING: MoveClipToTrack: Unable to resolve sequence for clip " .. tostring(clip_id))
            return false
        end
        clip.owner_sequence_id = clip.owner_sequence_id or mutation_sequence

        command:set_parameter("original_track_id", clip.track_id)

        if dry_run then
            return true, {
                clip_id = clip_id,
                original_track_id = clip.track_id,
                new_track_id = target_track_id
            }
        end

        local original_timeline_start = clip.timeline_start

        -- Check for pending_new_start_value
        local pending_new_start_rat = command:get_parameter("pending_new_start_rat")
        if type(pending_new_start_rat) == "table" and pending_new_start_rat.frames and not getmetatable(pending_new_start_rat) then
            pending_new_start_rat = Rational.new(pending_new_start_rat.frames, pending_new_start_rat.fps_numerator, pending_new_start_rat.fps_denominator)
        end

        local pending_duration_rat = command:get_parameter("pending_duration_rat")
        if type(pending_duration_rat) == "table" and pending_duration_rat.frames and not getmetatable(pending_duration_rat) then
            pending_duration_rat = Rational.new(pending_duration_rat.frames, pending_duration_rat.fps_numerator, pending_duration_rat.fps_denominator)
        end

        if pending_new_start_rat then
            -- Store original timeline_start before changing it for a potential move during save
            command:set_parameter("original_timeline_start_rat", clip.timeline_start)
            clip.timeline_start = pending_new_start_rat
        end

        -- Resolve Occlusions on Target Track
        -- Must happen before saving the moved clip to clear space
        local target_start = clip.timeline_start
        local target_duration = pending_duration_rat or clip.duration
        
        local ok_occ, err_occ, actions = clip_mutator.resolve_occlusions(db, {
            track_id = target_track_id,
            timeline_start = target_start,
            duration = target_duration,
            exclude_clip_id = clip.id -- Don't trim self if we are just moving on same track (though track_id changed here)
        })
        
        if not ok_occ then
            print(string.format("ERROR: MoveClipToTrack: Failed to resolve occlusions: %s", tostring(err_occ)))
            return false
        end
        
        record_occlusion_actions(command, mutation_sequence, actions)

        clip.track_id = target_track_id

        local save_opts = nil
        local skip_occlusion = command:get_parameter("skip_occlusion") == true
        if skip_occlusion or pending_new_start_rat then
            save_opts = save_opts or {}
            if skip_occlusion then
                save_opts.skip_occlusion = true
            end
            if pending_new_start_rat then
                local current_clip_duration = pending_duration_rat or clip.duration
                save_opts.pending_clips = save_opts.pending_clips or {}
                save_opts.pending_clips[clip.id] = {
                    timeline_start = pending_new_start_rat,
                    duration = current_clip_duration,
                    -- Tolerance needs to be rational or removed from here
                    -- For now, use a default Rational tolerance
                    tolerance = Rational.new(1, current_clip_duration.fps_numerator, current_clip_duration.fps_denominator) -- 1 frame tolerance
                }
            end
        end

        if not clip:save(db, save_opts) then
            print(string.format("WARNING: MoveClipToTrack: Failed to save clip %s", clip_id))
            return false
        end

        local update = {
            clip_id = clip.id,
            track_id = clip.track_id,
            track_sequence_id = clip.owner_sequence_id or clip.track_sequence_id,
            timeline_start = clip.timeline_start,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out
        }

        local update_sequence = clip.owner_sequence_id or clip.track_sequence_id or mutation_sequence
        update.track_sequence_id = update_sequence
        command_helper.add_update_mutation(command, update_sequence, update)

        print(string.format("✅ Moved clip %s to track %s at %s", clip_id, target_track_id, tostring(clip.timeline_start)))
        return true
    end

    command_undoers["UndoMoveClipToTrack"] = function(command)
        print("Executing UndoMoveClipToTrack command")

        local clip_id = command:get_parameter("clip_id")
        local original_track_id = command:get_parameter("original_track_id")
        local original_timeline_start = command:get_parameter("original_timeline_start_rat")
        
        -- Hydrate original_timeline_start if needed
        if type(original_timeline_start) == "table" and original_timeline_start.frames and not getmetatable(original_timeline_start) then
            original_timeline_start = Rational.new(original_timeline_start.frames, original_timeline_start.fps_numerator, original_timeline_start.fps_denominator)
        end

        if not clip_id or clip_id == "" then
            print("WARNING: UndoMoveClipToTrack: Missing clip_id")
            return false
        end

        if not original_track_id or original_track_id == "" then
            print("WARNING: UndoMoveClipToTrack: Missing original_track_id parameter")
            return false
        end

        local clip = Clip.load(clip_id, db)

        if not clip then
            print(string.format("WARNING: UndoMoveClipToTrack: Clip %s not found", clip_id))
            return false
        end

        clip.track_id = original_track_id
        if original_timeline_start then
            clip.timeline_start = original_timeline_start
        end

        if not clip:save(db) then
            print(string.format("WARNING: UndoMoveClipToTrack: Failed to save clip %s", clip_id))
            return false
        end

        local update = {
            clip_id = clip.id,
            track_id = clip.track_id,
            track_sequence_id = clip.owner_sequence_id or clip.track_sequence_id,
            timeline_start = clip.timeline_start,
            duration = clip.duration,
            source_in = clip.source_in,
            source_out = clip.source_out
        }

        command_helper.add_update_mutation(command, clip.owner_sequence_id or clip.track_sequence_id, update)

        print(string.format("✅ Restored clip %s to original track %s at %s", clip_id, original_track_id, tostring(clip.timeline_start)))
        return true
    end

    command_executors["UndoMoveClipToTrack"] = command_undoers["UndoMoveClipToTrack"]

    return {
        executor = command_executors["MoveClipToTrack"],
        undoer = command_executors["UndoMoveClipToTrack"]
    }
end

return M
