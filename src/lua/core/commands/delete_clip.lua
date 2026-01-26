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
-- Size: ~115 LOC
-- Volatility: unknown
--
-- @file delete_clip.lua
local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")


local SPEC = {
    args = {
        clip_id = { required = true },
        deleted_clip_properties = {},
        deleted_clip_state = {},
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DeleteClip"] = function(command)
        local args = command:get_all_parameters()
        print("Executing DeleteClip command")

        local clip = Clip.load_optional(args.clip_id)
        if not clip then

            if args.deleted_clip_state then
                command_helper.restore_clip_state(args.deleted_clip_state)
                clip = Clip.load_optional(args.clip_id)
            end
        end
        if not clip then
            print(string.format("INFO: DeleteClip: Clip %s already absent during replay; skipping delete", args.clip_id))
            return true
        end

        local sequence_id = args.sequence_id
            or clip.owner_sequence_id
            or clip.track_sequence_id
            or (clip.track and clip.track.sequence_id)

        if sequence_id then
            command:set_parameter("sequence_id", sequence_id)
        end

        local clip_state = command_helper.capture_clip_state(clip)
        command:set_parameters({
            ["deleted_clip_state"] = clip_state,
            ["deleted_clip_properties"] = command_helper.snapshot_properties_for_clip(args.clip_id),
        })
        command_helper.delete_properties_for_clip(args.clip_id)

        if not clip:delete() then
            print(string.format("WARNING: DeleteClip: Failed to delete clip %s", args.clip_id))
            return false
        end

        if sequence_id then
            command_helper.add_delete_mutation(command, sequence_id, clip.id)
        end

        print(string.format("✅ Deleted clip %s from timeline", args.clip_id))
        return true
    end

    command_undoers["DeleteClip"] = function(command)
        local args = command:get_all_parameters()

        if not args.deleted_clip_state then
            set_last_error("DeleteClip undo: Missing clip state")
            return false
        end

        command_helper.restore_clip_state(args.deleted_clip_state)
        local properties = args.deleted_clip_properties or {}
        if #properties > 0 then
            command_helper.insert_properties_for_clip(args.deleted_clip_state.id, properties)
        end

        -- Ensure timeline cache gets the restored clip without requiring a full reload.
        -- Replace forward-delete mutations with an insert mutation for this undo.
        local seq_id = args.sequence_id or args.deleted_clip_state.owner_sequence_id or args.deleted_clip_state.track_sequence_id
        local restored_clip = Clip.load_optional(args.deleted_clip_state.id)
        local payload = nil
        local target_seq = seq_id
        if restored_clip then
            payload = command_helper.clip_insert_payload(restored_clip, seq_id)
            target_seq = target_seq or (payload and (payload.track_sequence_id or payload.owner_sequence_id)) or restored_clip.owner_sequence_id
        else
            -- fallback payload built from captured state
            payload = command_helper.clip_insert_payload({
                id = args.deleted_clip_state.id,
                project_id = args.deleted_clip_state.project_id or args.project_id,
                clip_kind = args.deleted_clip_state.clip_kind or "timeline",
                track_id = args.deleted_clip_state.track_id,
                owner_sequence_id = args.deleted_clip_state.owner_sequence_id or seq_id,
                track_sequence_id = args.deleted_clip_state.track_sequence_id or seq_id,
                timeline_start = args.deleted_clip_state.timeline_start,
                duration = args.deleted_clip_state.duration,
                source_in = args.deleted_clip_state.source_in,
                source_out = args.deleted_clip_state.source_out,
                fps_numerator = args.deleted_clip_state.fps_numerator,
                fps_denominator = args.deleted_clip_state.fps_denominator,
                enabled = args.deleted_clip_state.enabled ~= false
            }, seq_id)
            target_seq = target_seq or args.deleted_clip_state.owner_sequence_id or args.deleted_clip_state.track_sequence_id or seq_id
        end

        if target_seq then
            local bucket = {
                sequence_id = target_seq,
                inserts = {},
                updates = {},
                deletes = {}
            }
            if payload then
                table.insert(bucket.inserts, payload)
            end
            command.parameters["__timeline_mutations"] = {[target_seq] = bucket}
        else
            command:set_parameter("__timeline_mutations", nil)
        end

        if not args.__timeline_mutations then
            local msg = string.format(
                "DeleteClip undo failed to set timeline mutations (seq_id=%s, payload=%s, clip_loaded=%s)",
                tostring(seq_id),
                payload and "yes" or "nil",
                restored_clip and "yes" or "nil"
            )
            print("ERROR: " .. msg)
            return false, msg
        end
        print(string.format("✅ Undo DeleteClip: Restored clip %s", args.deleted_clip_state.id))
        return true
    end

    return {
        executor = command_executors["DeleteClip"],
        undoer = command_undoers["DeleteClip"],
        spec = SPEC,
    }
end

return M
