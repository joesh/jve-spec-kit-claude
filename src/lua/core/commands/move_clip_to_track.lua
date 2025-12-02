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
        local original_state = command_helper.capture_clip_state(clip)

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
        local target_start = clip.timeline_start
        local target_duration = pending_duration_rat or clip.duration
        
        local ok_occ, err_occ, planned_mutations = clip_mutator.resolve_occlusions(db, {
            track_id = target_track_id,
            timeline_start = target_start,
            duration = target_duration,
            exclude_clip_id = clip.id 
        })
        
        if not ok_occ then
            print(string.format("ERROR: MoveClipToTrack: Failed to resolve occlusions: %s", tostring(err_occ)))
            return false
        end
        
        -- Plan the move itself
        clip.track_id = target_track_id
        -- Pending start/duration were already applied to `clip` object above if pending_new_start_rat was set?
        -- Wait, lines 87-90:
        -- if pending_new_start_rat then
        --    clip.timeline_start = pending_new_start_rat
        -- end
        -- So `clip` is already modified in memory.
        
        table.insert(planned_mutations, clip_mutator.plan_update(clip, original_state))

        -- Debug
        for i, m in ipairs(planned_mutations) do
            print(string.format("DEBUG Mutation %d: %s id=%s track=%s start=%s dur=%s", 
                i, m.type, tostring(m.clip_id), tostring(m.track_id), tostring(m.timeline_start_frame), tostring(m.duration_frames)))
        end

        -- Execute all mutations
        local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
        if not ok_apply then
            return false, "Failed to apply mutations: " .. tostring(apply_err)
        end

        command:set_parameter("executed_mutations", planned_mutations)

        print(string.format("✅ Moved clip %s to track %s at %s", clip_id, target_track_id, tostring(clip.timeline_start)))
        return true
    end

    command_undoers["UndoMoveClipToTrack"] = function(command)
        print("Executing UndoMoveClipToTrack command")

        local executed_mutations = command:get_parameter("executed_mutations")
        -- Fallback for legacy undo if executed_mutations missing? 
        -- The old undoer logic is incompatible with the new occlusion handling (doesn't restore deleted clips).
        -- So we enforce new logic.
        
        if not executed_mutations then
             print("WARNING: UndoMoveClipToTrack: No executed mutations found (legacy command?)")
             return false
        end
        
        -- We need sequence_id to record UI mutations during revert
        -- It's not passed explicitly, but we can try to resolve it or pass nil (UI falls back to reload)
        local sequence_id = nil -- Not critical for DB consistency

        local started, begin_err = db:begin_transaction()
        if not started then
            print("WARNING: UndoMoveClipToTrack: Proceeding without transaction: " .. tostring(begin_err))
        end

        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, sequence_id)
        if not ok then
            if started then db:rollback_transaction(started) end
            print("ERROR: UndoMoveClipToTrack: Failed to revert mutations: " .. tostring(err))
            return false
        end
        
        if started then
            local ok_commit, commit_err = db:commit_transaction(started)
            if not ok_commit then
                db:rollback_transaction(started)
                return false, "Failed to commit undo transaction: " .. tostring(commit_err)
            end
        end

        print("✅ Restored clip move and occlusions")
        return true
    end

    command_executors["UndoMoveClipToTrack"] = command_undoers["UndoMoveClipToTrack"]

    return {
        executor = command_executors["MoveClipToTrack"],
        undoer = command_executors["UndoMoveClipToTrack"]
    }
end

return M
