local M = {}
local log = require("core.logger").for_area("commands")
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
    --- Convert clip_mutator planned_mutations into __timeline_mutations for UI cache.
    local function record_planned_mutations(command, sequence_id, planned_mutations)
        if not planned_mutations or #planned_mutations == 0 then return end
        for _, mut in ipairs(planned_mutations) do
            assert(mut.type, "record_planned_mutations: mutation missing type")
            assert(mut.clip_id, string.format(
                "record_planned_mutations: %s mutation missing clip_id", mut.type))
            if mut.type == "delete" then
                command_helper.add_delete_mutation(command, sequence_id, mut.clip_id)
            elseif mut.type == "update" then
                assert(mut.track_id, string.format(
                    "record_planned_mutations: update mutation missing track_id (clip=%s)", mut.clip_id))
                command_helper.add_update_mutation(command, sequence_id, {
                    clip_id = mut.clip_id,
                    track_id = mut.track_id,
                    start_value = mut.timeline_start_frame,
                    duration_value = mut.duration_frames,
                    source_in_value = mut.source_in_frame,
                    source_out_value = mut.source_out_frame,
                    enabled = mut.enabled == 1,
                })
            elseif mut.type == "insert" then
                assert(mut.track_id, string.format(
                    "record_planned_mutations: insert mutation missing track_id (clip=%s)", mut.clip_id))
                command_helper.add_insert_mutation(command, sequence_id, {
                    id = mut.clip_id,
                    track_id = mut.track_id,
                    start_value = mut.timeline_start_frame,
                    duration_value = mut.duration_frames,
                    source_in_value = mut.source_in_frame,
                    source_out_value = mut.source_out_frame,
                    enabled = mut.enabled == 1,
                })
            else
                error(string.format(
                    "record_planned_mutations: unknown mutation type '%s' (clip=%s)",
                    tostring(mut.type), tostring(mut.clip_id)))
            end
        end
    end

    command_executors["MoveClipToTrack"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            log.event("Executing MoveClipToTrack")
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

        local _original_timeline_start = clip.timeline_start  -- luacheck: ignore 211 (preserved for future undo enhancement)
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

        -- Populate __timeline_mutations for UI cache update
        record_planned_mutations(command, mutation_sequence, planned_mutations)

        log.event("Moved clip %s to track %s at %s",
            clip_id, args.target_track_id, tostring(clip.timeline_start))
        return true
    end

    command_undoers["MoveClipToTrack"] = function(command)
        local args = command:get_all_parameters()
        log.event("Executing UndoMoveClipToTrack")

        if not args.executed_mutations then
             local msg = "UndoMoveClipToTrack: No executed mutations found (legacy command?)"
             log.warn("%s", msg)
             return { success = false, error_message = msg }
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

        -- No transaction here — command_manager provides one
        local ok, err = command_helper.revert_mutations(db, args.executed_mutations, command, sequence_id)
        if not ok then
            return {success = false, error_message = "UndoMoveClipToTrack: revert_mutations failed: " .. tostring(err)}
        end
        return {success = true}
    end

    -- Explicit "UndoMoveClipToTrack" command (Command:create_undo() builds
    -- one with this type). Same body as the regular undoer.
    command_executors["UndoMoveClipToTrack"] = command_undoers["MoveClipToTrack"]

    return {
        executor = command_executors["MoveClipToTrack"],
        undoer   = command_undoers["MoveClipToTrack"],
        spec     = SPEC,
    }
end

return M
