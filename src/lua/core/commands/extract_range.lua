--- ExtractRange — lift mark range then ripple-close the gap.
--
-- NLE "Extract" operation: removes clip material in [mark_in, mark_out)
-- across all tracks, then shifts everything after mark_out left to close the gap.
--
-- @file extract_range.lua
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
                media_id = mut.media_id,
                master_clip_id = mut.master_clip_id,
                owner_sequence_id = mut.owner_sequence_id,
                enabled = mut.enabled ~= false,
                clip_kind = mut.clip_kind,
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
    command_executors["ExtractRange"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "ExtractRange: db is nil")

        local sequence_id = assert(args.sequence_id, "ExtractRange: sequence_id required")
        local mark_in = assert(args.mark_in, "ExtractRange: mark_in required")
        local mark_out = assert(args.mark_out, "ExtractRange: mark_out required")
        assert(type(mark_in) == "number", "ExtractRange: mark_in must be integer")
        assert(type(mark_out) == "number", "ExtractRange: mark_out must be integer")

        local range_duration = mark_out - mark_in
        assert(range_duration > 0,
            string.format("ExtractRange: empty range (mark_in=%d, mark_out=%d)", mark_in, mark_out))

        local tracks = Track.find_by_sequence(sequence_id)

        -- Phase 1: Lift — resolve occlusions on every track
        local lift_mutations = {}
        for _, track in ipairs(tracks) do
            local ok, err, mutations = clip_mutator.resolve_occlusions(db, {
                track_id = track.id,
                timeline_start = mark_in,
                duration = range_duration,
            })
            if not ok then
                set_last_error("ExtractRange: occlusion failed: " .. tostring(err))
                return false
            end
            for _, mut in ipairs(mutations or {}) do
                table.insert(lift_mutations, mut)
            end
        end

        -- Apply lift mutations so ripple operates on post-lift state
        if #lift_mutations > 0 then
            local ok_apply, apply_err = command_helper.apply_mutations(db, lift_mutations)
            if not ok_apply then
                set_last_error("ExtractRange: apply lift failed: " .. tostring(apply_err))
                return false
            end
        end

        -- Phase 2: Ripple — shift clips at/after mark_in left by range_duration
        local ripple_mutations = {}
        for _, track in ipairs(tracks) do
            local ok, err, mutations = clip_mutator.resolve_ripple(db, {
                track_id = track.id,
                insert_time = mark_in,
                shift_amount = -range_duration,
            })
            if not ok then
                set_last_error("ExtractRange: ripple failed: " .. tostring(err))
                return false
            end
            for _, mut in ipairs(mutations or {}) do
                table.insert(ripple_mutations, mut)
            end
        end

        if #ripple_mutations > 0 then
            local ok_apply, apply_err = command_helper.apply_mutations(db, ripple_mutations)
            if not ok_apply then
                set_last_error("ExtractRange: apply ripple failed: " .. tostring(apply_err))
                return false
            end
        end

        -- Store all mutations (lift + ripple) for undo
        local all_mutations = {}
        for _, m in ipairs(lift_mutations) do table.insert(all_mutations, m) end
        for _, m in ipairs(ripple_mutations) do table.insert(all_mutations, m) end

        command:set_parameter("executed_mutations", all_mutations)
        populate_timeline_mutations(command, sequence_id, all_mutations)

        log.event("ExtractRange: extracted [%d, %d), %d lift + %d ripple mutations",
            mark_in, mark_out, #lift_mutations, #ripple_mutations)
        return true
    end

    command_undoers["ExtractRange"] = function(command)
        local args = command:get_all_parameters()
        assert(db, "UndoExtractRange: db is nil")

        local executed_mutations = args.executed_mutations or {}
        if #executed_mutations == 0 then
            return true
        end

        local ok, err = command_helper.revert_mutations(db, executed_mutations, command, args.sequence_id)
        assert(ok, "UndoExtractRange: revert_mutations failed: " .. tostring(err))

        log.event("Undo ExtractRange: reverted %d mutation(s)", #executed_mutations)
        return true
    end

    command_executors["UndoExtractRange"] = command_undoers["ExtractRange"]

    return {
        executor = command_executors["ExtractRange"],
        undoer = command_undoers["ExtractRange"],
        spec = SPEC,
    }
end

return M
