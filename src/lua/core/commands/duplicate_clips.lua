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
-- Size: ~108 LOC
-- Volatility: unknown
--
-- @file duplicate_clips.lua
local M = {}

local Clip = require("models.clip")
local command_helper = require("core.command_helper")
local clip_mutator = require("core.clip_mutator")


local SPEC = {
    args = {
        anchor_clip_id = { required = true },
        clip_ids = {},
        delta_frames = { kind = "number" },
        project_id = { required = true },
        sequence_id = { required = true },
        target_track_id = { required = true },
    },
    persisted = {
        executed_mutations = {},
    },

}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DuplicateClips"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "DuplicateClips: db is nil")
        assert(command and command.get_parameter, "DuplicateClips: invalid command handle")

        local sequence_id = args.sequence_id
        if not sequence_id or sequence_id == "" then
            return false, "DuplicateClips: missing sequence_id"
        end
        if not args.__snapshot_sequence_ids then
            command:set_parameter("__snapshot_sequence_ids", {sequence_id})
        end

        local clip_ids = args.clip_ids
        if type(clip_ids) ~= "table" or #clip_ids == 0 then
            return false, "DuplicateClips: missing clip_ids"
        end

        local target_track_id = args.target_track_id
        if not target_track_id or target_track_id == "" then
            return false, "DuplicateClips: missing target_track_id"
        end

        -- Delta must be integer frames
        local delta_frames = args.delta_frames or 0
        assert(type(delta_frames) == "number", "DuplicateClips: delta_frames must be integer")

        local anchor_clip_id = args.anchor_clip_id or clip_ids[1]
        if not anchor_clip_id or anchor_clip_id == "" then
            return false, "DuplicateClips: missing anchor_clip_id"
        end

        local ok_plan, plan_err, plan = clip_mutator.plan_duplicate_block(db, {
            sequence_id = sequence_id,
            clip_ids = clip_ids,
            delta_frames = delta_frames,
            target_track_id = target_track_id,
            anchor_clip_id = anchor_clip_id,
        })
        if not ok_plan then
            return false, plan_err
        end

        local planned_mutations = plan and plan.planned_mutations or {}
        local new_clip_ids = plan and plan.new_clip_ids or {}
        if #planned_mutations == 0 then
            return true
        end

        local ok_apply, apply_err = command_helper.apply_mutations(db, planned_mutations)
        if not ok_apply then
            return false, "DuplicateClips: apply_mutations failed: " .. tostring(apply_err)
        end

        command:set_parameters({
            ["executed_mutations"] = planned_mutations,
            ["new_clip_ids"] = new_clip_ids,
        })
        for _, mut in ipairs(planned_mutations) do
            if mut.type == "insert" then
                local inserted = Clip.load_optional(mut.clip_id)
                if inserted then
                    local payload = command_helper.clip_insert_payload(inserted, sequence_id)
                    if payload then
                        command_helper.add_insert_mutation(command, sequence_id, payload)
                    end
                end
            elseif mut.type == "delete" then
                command_helper.add_delete_mutation(command, sequence_id, mut.clip_id)
            elseif mut.type == "update" then
                local updated = Clip.load_optional(mut.clip_id)
                if updated then
                    local payload = command_helper.clip_update_payload(updated, sequence_id)
                    if payload then
                        command_helper.add_update_mutation(command, sequence_id, payload)
                    end
                end
            end
        end

        return true
    end

    command_undoers["DuplicateClips"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "UndoDuplicateClips: db is nil")
        assert(command and command.get_parameter, "UndoDuplicateClips: invalid command handle")



        if type(args.executed_mutations) ~= "table" or #args.executed_mutations == 0 then
            return true
        end

        local started, begin_err = db:begin_transaction()
        assert(started, "UndoDuplicateClips: failed to begin transaction: " .. tostring(begin_err))

        local ok, err = command_helper.revert_mutations(db, args.executed_mutations, command, args.sequence_id)
        if not ok then
            if started then db:rollback_transaction(started) end
            return false, "UndoDuplicateClips: revert_mutations failed: " .. tostring(err)
        end

        local ok_commit, commit_err = db:commit_transaction(started)
        if not ok_commit then
            db:rollback_transaction(started)
            return false, "UndoDuplicateClips: commit failed: " .. tostring(commit_err)
        end

        return true
    end

    command_executors["UndoDuplicateClips"] = command_undoers["DuplicateClips"]

    return {
        executor = command_executors["DuplicateClips"],
        undoer = command_undoers["DuplicateClips"],
        spec = SPEC,
    }
end

return M
