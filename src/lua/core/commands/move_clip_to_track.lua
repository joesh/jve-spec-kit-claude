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
-- Size: ~184 LOC
-- Volatility: unknown
--
-- @file move_clip_to_track.lua
local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local clip_mutator = require("core.clip_mutator")


local SPEC = {
    args = {
        clip_id = { required = true },
        dry_run = { kind = "boolean" },
        pending_duration = { kind = "number" },
        pending_new_start = { kind = "number" },
        project_id = { required = true },
        sequence_id = {},
        skip_occlusion = { kind = "boolean" },
        target_track_id = { required = true },
    },
    persisted = {
        executed_mutations = {},
        original_timeline_start = {},  -- Set by executor for undo (integer frames)
        original_track_id = {},  -- Set by executor for undo
        pending_clips = {},
    },

}

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
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing MoveClipToTrack command")
        end

        local clip_id = args.clip_id




        local clip = Clip.load(clip_id)
        -- NSF: Clip must exist for move operation
        assert(clip, string.format("MoveClipToTrack: clip %s not found", clip_id))

        -- Resolve mutation_sequence: prefer clip's owner, then lookup from track
        local mutation_sequence = clip.owner_sequence_id or clip.track_sequence_id
        if (not mutation_sequence or mutation_sequence == "") and clip.track_id then
            local seq_lookup = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
            assert(seq_lookup, "MoveClipToTrack: failed to prepare sequence lookup query")
            seq_lookup:bind_value(1, clip.track_id)
            if seq_lookup:exec() and seq_lookup:next() then
                mutation_sequence = seq_lookup:value(0)
            end
            seq_lookup:finalize()
        end
        if not mutation_sequence or mutation_sequence == "" then
            -- Try target track as fallback
            local target_lookup = db:prepare("SELECT sequence_id FROM tracks WHERE id = ?")
            assert(target_lookup, "MoveClipToTrack: failed to prepare target sequence lookup query")
            target_lookup:bind_value(1, args.target_track_id)
            if target_lookup:exec() and target_lookup:next() then
                mutation_sequence = target_lookup:value(0)
            end
            target_lookup:finalize()
        end
        -- NSF: mutation_sequence is required - no fallback
        assert(mutation_sequence and mutation_sequence ~= "",
            string.format("MoveClipToTrack: unable to resolve sequence for clip %s (track_id=%s, target_track_id=%s)",
                clip_id, tostring(clip.track_id), tostring(args.target_track_id)))
        clip.owner_sequence_id = clip.owner_sequence_id or mutation_sequence
        command:set_parameters({
            ["sequence_id"] = mutation_sequence,
            ["original_track_id"] = clip.track_id,
        })
        if args.dry_run then
            return true, {
                clip_id = clip_id,
                original_track_id = clip.track_id,
                new_track_id = args.target_track_id
            }
        end

        local original_timeline_start = clip.timeline_start
        local original_state = command_helper.capture_clip_state(clip)

        -- Pending values must be integers (if provided)
        local pending_new_start = args.pending_new_start
        local pending_duration = args.pending_duration
        if pending_new_start then
            assert(type(pending_new_start) == "number", "MoveClipToTrack: pending_new_start must be integer")
        end
        if pending_duration then
            assert(type(pending_duration) == "number", "MoveClipToTrack: pending_duration must be integer")
        end

        if pending_new_start then
            command:set_parameter("original_timeline_start", clip.timeline_start)
            clip.timeline_start = pending_new_start
        end

        -- Resolve Occlusions on Target Track
        local target_start = clip.timeline_start
        local target_duration = pending_duration or clip.duration
        local pending_clips = args.pending_clips

        local ok_occ, err_occ, planned_mutations = clip_mutator.resolve_occlusions(db, {
            track_id = args.target_track_id,
            timeline_start = target_start,
            duration = target_duration,
            exclude_clip_id = clip.id,
            pending_clips = pending_clips
        })
        
        if not ok_occ then
            -- NSF: Return structured error, not just false
            return {success = false, error_message = string.format("MoveClipToTrack: Failed to resolve occlusions: %s", tostring(err_occ))}
        end
        
        -- Plan the move itself
        clip.track_id = args.target_track_id
        -- Pending start/duration were already applied to `clip` object above if pending_new_start_rat was set?
        -- Wait, lines 87-90:
        -- if pending_new_start_rat then
        --    clip.timeline_start = pending_new_start_rat
        -- end
        -- So `clip` is already modified in memory.
        
        table.insert(planned_mutations, clip_mutator.plan_update(clip, original_state))

        -- Execute all mutations
        local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
        if not ok_apply then
            -- NSF: Return structured error, not tuple
            return {success = false, error_message = "MoveClipToTrack: Failed to apply mutations: " .. tostring(apply_err)}
        end

        command:set_parameter("executed_mutations", planned_mutations)

        print(string.format("✅ Moved clip %s to track %s at %s", clip_id, args.target_track_id, tostring(clip.timeline_start)))
        return true
    end

    command_undoers["UndoMoveClipToTrack"] = function(command)
        local args = command:get_all_parameters()
        print("Executing UndoMoveClipToTrack command")


        -- Fallback for legacy undo if args.executed_mutations missing? 
        -- The old undoer logic is incompatible with the new occlusion handling (doesn't restore deleted clips).
        -- So we enforce new logic.
        
        if not args.executed_mutations then
             local msg = "UndoMoveClipToTrack: No executed mutations found (legacy command?)"
             print("WARNING: " .. msg)
             return {success = false, error_message = msg}
        end
        
        -- We need sequence_id to record UI mutations during revert
        -- Prefer explicit sequence id saved on the command; fall back to mutation provenance.
        local sequence_id = args.sequence_id
        if (not sequence_id or sequence_id == "") and type(args.executed_mutations) == "table" then
            for _, mut in ipairs(args.executed_mutations) do
                if mut.previous and mut.previous.track_sequence_id then
                    sequence_id = mut.previous.track_sequence_id
                    break
                end
                if mut.previous and mut.previous.owner_sequence_id then
                    sequence_id = mut.previous.owner_sequence_id
                    break
                end
            end
        end
        -- NSF: sequence_id is required for undo - assert we resolved it
        assert(sequence_id and sequence_id ~= "",
            "UndoMoveClipToTrack: could not resolve sequence_id from command args or mutations")
        command:set_parameter("sequence_id", sequence_id)

        local started, begin_err = db:begin_transaction()
        if not started then
            print("WARNING: UndoMoveClipToTrack: Proceeding without transaction: " .. tostring(begin_err))
        end

        local ok, err = command_helper.revert_mutations(db, args.executed_mutations, command, sequence_id)
        if not ok then
            if started then db:rollback_transaction(started) end
            local msg = "UndoMoveClipToTrack: Failed to revert mutations: " .. tostring(err)
            print("ERROR: " .. msg)
            return {success = false, error_message = msg}
        end
        
        if started then
            local ok_commit, commit_err = db:commit_transaction(started)
            if not ok_commit then
                db:rollback_transaction(started)
                local msg = "Failed to commit undo transaction: " .. tostring(commit_err)
                print("ERROR: " .. msg)
                return {success = false, error_message = msg}
            end
        end

        print("✅ Restored clip move and occlusions")
        return {success = true}
    end

    command_executors["UndoMoveClipToTrack"] = command_undoers["UndoMoveClipToTrack"]
    -- Register undoer under the execute type so command_manager picks it directly.
    command_undoers["MoveClipToTrack"] = command_undoers["UndoMoveClipToTrack"]

    return {
        executor = command_executors["MoveClipToTrack"],
        undoer = command_executors["UndoMoveClipToTrack"],
        spec = SPEC,
    }
end

return M
