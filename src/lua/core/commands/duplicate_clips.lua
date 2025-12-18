local M = {}

local Clip = require("models.clip")
local command_helper = require("core.command_helper")
local clip_mutator = require("core.clip_mutator")
local Rational = require("core.rational")
local rational_helpers = require("core.command_rational_helpers")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DuplicateClips"] = function(command)
        assert(db, "DuplicateClips: db is nil")
        assert(command and command.get_parameter, "DuplicateClips: invalid command handle")

        local sequence_id = command:get_parameter("sequence_id")
        if not sequence_id or sequence_id == "" then
            return false, "DuplicateClips: missing sequence_id"
        end
        if not command:get_parameter("__snapshot_sequence_ids") then
            command:set_parameter("__snapshot_sequence_ids", {sequence_id})
        end

        local clip_ids = command:get_parameter("clip_ids")
        if type(clip_ids) ~= "table" or #clip_ids == 0 then
            return false, "DuplicateClips: missing clip_ids"
        end

        local target_track_id = command:get_parameter("target_track_id")
        if not target_track_id or target_track_id == "" then
            return false, "DuplicateClips: missing target_track_id"
        end

        local seq_fps_num, seq_fps_den = rational_helpers.require_sequence_rate(db, sequence_id)
        local delta_rat = command:get_parameter("delta_rat")
        delta_rat = Rational.hydrate(delta_rat, seq_fps_num, seq_fps_den) or Rational.new(0, seq_fps_num, seq_fps_den)
        if delta_rat.fps_numerator ~= seq_fps_num or delta_rat.fps_denominator ~= seq_fps_den then
            delta_rat = Rational.new(delta_rat.frames, seq_fps_num, seq_fps_den)
        end

        local anchor_clip_id = command:get_parameter("anchor_clip_id") or clip_ids[1]
        if not anchor_clip_id or anchor_clip_id == "" then
            return false, "DuplicateClips: missing anchor_clip_id"
        end

        local ok_plan, plan_err, plan = clip_mutator.plan_duplicate_block(db, {
            sequence_id = sequence_id,
            clip_ids = clip_ids,
            delta_rat = delta_rat,
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

        command:set_parameter("executed_mutations", planned_mutations)
        command:set_parameter("new_clip_ids", new_clip_ids)

        for _, mut in ipairs(planned_mutations) do
            if mut.type == "insert" then
                local inserted = Clip.load_optional(mut.clip_id, db)
                if inserted then
                    local payload = command_helper.clip_insert_payload(inserted, sequence_id)
                    if payload then
                        command_helper.add_insert_mutation(command, sequence_id, payload)
                    end
                end
            elseif mut.type == "delete" then
                command_helper.add_delete_mutation(command, sequence_id, mut.clip_id)
            elseif mut.type == "update" then
                local updated = Clip.load_optional(mut.clip_id, db)
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
        assert(db, "UndoDuplicateClips: db is nil")
        assert(command and command.get_parameter, "UndoDuplicateClips: invalid command handle")

        local executed_mutations = command:get_parameter("executed_mutations")
        local sequence_id = command:get_parameter("sequence_id")
        if type(executed_mutations) ~= "table" or #executed_mutations == 0 then
            return true
        end

        local started, begin_err = db:begin_transaction()
        assert(started, "UndoDuplicateClips: failed to begin transaction: " .. tostring(begin_err))

        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, sequence_id)
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
    }
end

return M
