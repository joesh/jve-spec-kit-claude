--- LiftRange — remove all clip material in [mark_in, mark_out) across all tracks.
--
-- NLE "Lift" operation: clips fully inside the range are deleted,
-- clips partially overlapping are trimmed. Leaves a gap (no ripple).
--
-- @file lift_range.lua
local M = {}

local clip_mutator = require("core.clip_mutator")
local command_helper = require("core.command_helper")
local Track = require("models.track")
local log = require("core.logger").for_area("commands")

local SPEC = {
    args = {
        project_id = { required = true },
        sequence_id = { required = true },
        mark_in = { required = true },
        mark_out = { required = true },
    },
    persisted = {
        executed_mutations = {},
    },
}

--- Populate __timeline_mutations for UI cache updates.
local function populate_timeline_mutations(command, sequence_id, mutations)
    for _, mut in ipairs(mutations) do
        if mut.type == "insert" then
            command_helper.add_insert_mutation(command, sequence_id, {
                id = mut.clip_id,
                track_id = mut.track_id,
                start_value = mut.timeline_start_frame,
                duration_value = mut.duration_frames,
                source_in_value = mut.source_in_frame,
                source_out_value = mut.source_out_frame,
                name = mut.name,
                nested_sequence_id = mut.nested_sequence_id,
                master_layer_track_id = mut.master_layer_track_id,
                master_audio_track_id = mut.master_audio_track_id,
                fps_mismatch_policy = mut.fps_mismatch_policy,
                owner_sequence_id = mut.owner_sequence_id,
                enabled = mut.enabled ~= false,
                track_type = mut.track_type,
                fps_numerator = mut.fps_numerator,
                fps_denominator = mut.fps_denominator,
            })
        elseif mut.type == "update" then
            command_helper.add_update_mutation(command, sequence_id, {
                clip_id = mut.clip_id,
                track_id = mut.track_id,
                start_value = mut.timeline_start_frame,
                duration_value = mut.duration_frames,
                source_in_value = mut.source_in_frame,
                source_out_value = mut.source_out_frame,
            })
        elseif mut.type == "delete" then
            command_helper.add_delete_mutation(command, sequence_id, mut.clip_id)
        end
    end
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["LiftRange"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "LiftRange: db is nil")

        local sequence_id = assert(args.sequence_id, "LiftRange: sequence_id required")
        local mark_in = assert(args.mark_in, "LiftRange: mark_in required")
        local mark_out = assert(args.mark_out, "LiftRange: mark_out required")
        assert(type(mark_in) == "number", "LiftRange: mark_in must be integer")
        assert(type(mark_out) == "number", "LiftRange: mark_out must be integer")

        local range_duration = mark_out - mark_in
        assert(range_duration > 0,
            string.format("LiftRange: empty range (mark_in=%d, mark_out=%d)", mark_in, mark_out))

        -- Resolve occlusions on every track in the sequence
        local tracks = Track.find_by_sequence(sequence_id)
        local all_mutations = {}

        for _, track in ipairs(tracks) do
            local ok, err, mutations = clip_mutator.resolve_occlusions(db, {
                track_id = track.id,
                timeline_start = mark_in,
                duration = range_duration,
            })
            if not ok then
                set_last_error("LiftRange: occlusion failed on track "
                    .. tostring(track.id) .. ": " .. tostring(err))
                return false
            end
            for _, mut in ipairs(mutations or {}) do
                table.insert(all_mutations, mut)
            end
        end

        if #all_mutations == 0 then
            log.event("LiftRange: no clips in range [%d, %d)", mark_in, mark_out)
            return true
        end

        -- Apply mutations
        local ok_apply, apply_err = command_helper.apply_mutations(db, all_mutations)
        if not ok_apply then
            set_last_error("LiftRange: apply_mutations failed: " .. tostring(apply_err))
            return false
        end

        -- Store for undo
        command:set_parameter("executed_mutations", all_mutations)
        populate_timeline_mutations(command, sequence_id, all_mutations)

        log.event("LiftRange: lifted %d mutation(s) in [%d, %d)", #all_mutations, mark_in, mark_out)
        return true
    end

    command_undoers["LiftRange"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "UndoLiftRange: db is nil")

        local executed_mutations = args.executed_mutations or {}
        if #executed_mutations == 0 then
            return true
        end

        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, args.sequence_id)
        assert(ok, "UndoLiftRange: revert_mutations failed: " .. tostring(err))

        log.event("Undo LiftRange: reverted %d mutation(s)", #executed_mutations)
        return true
    end

    command_executors["UndoLiftRange"] = command_undoers["LiftRange"]

    return {
        executor = command_executors["LiftRange"],
        undoer = command_undoers["LiftRange"],
        spec = SPEC,
    }
end

return M
