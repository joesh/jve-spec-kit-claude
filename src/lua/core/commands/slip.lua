--- Slip command (Feature 013, T044).
--
-- Slips a clip's source window by ±N nested-timebase frames. The clip's
-- position and duration on the owner timeline are UNCHANGED; only the
-- content inside the window moves.
--
-- Effect on the clip row:
--   sequence_start_frame  unchanged
--   duration_frames       unchanged
--   source_in_frame       += delta_source_frames
--   source_out_frame      += delta_source_frames
--
-- delta_source_frames is in nested-sequence timebase (per contracts/commands.md
-- §Slip). No fps_mismatch_policy conversion — Slip speaks the nested's own
-- timebase directly, since that's the space in which the window is valid.
--
-- Refuses: delta == 0, or any slip that pushes the window outside
-- [0, nested.effective_duration] (source window: non-empty, lower bound >= 0). Refusal is loud; DB unchanged.
--
-- SQL isolation: all DB access via models.
--
-- @file slip.lua

local M = {}

local Clip = require("models.clip")
local log  = require("core.logger").for_area("commands")

function M.execute(args)
    assert(type(args) == "table", "Slip.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "Slip: sequence_id required (rule 2.29)")
    assert(args.clip_id and args.clip_id ~= "",
        "Slip: clip_id required")
    assert(type(args.delta_source_frames) == "number",
        "Slip: delta_source_frames must be integer")
    local delta = args.delta_source_frames
    assert(delta ~= 0, "Slip: delta_source_frames must be non-zero")

    local clip = Clip.load_row(args.clip_id)
    assert(clip, string.format("Slip: clip %s not found", args.clip_id))
    assert(clip.owner_sequence_id == args.sequence_id, string.format(
        "Slip: clip %s owner_sequence_id=%s != args.sequence_id=%s",
        args.clip_id, clip.owner_sequence_id, args.sequence_id))

    local new_source_in  = clip.source_in_frame  + delta
    local new_source_out = clip.source_out_frame + delta

    Clip.assert_within_master_coverage(clip.sequence_id, new_source_out,
        "Slip clip=" .. args.clip_id)

    Clip.update_bounds(args.clip_id,
        clip.sequence_start_frame, clip.duration_frames,
        new_source_in, new_source_out)

    log.event("Slip clip=%s delta=%d", args.clip_id, delta)

    return {
        clip_id = args.clip_id,
        delta   = delta,
        prior   = {
            sequence_start_frame = clip.sequence_start_frame,
            duration_frames      = clip.duration_frames,
            source_in_frame      = clip.source_in_frame,
            source_out_frame     = clip.source_out_frame,
        },
    }
end

local SPEC = {
    args = {
        sequence_id         = { required = true },
        clip_id             = { required = true },
        delta_source_frames = { required = true },
    },
    persisted = {
        prior_state = {},
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Slip"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Slip: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("prior_state", result_or_err.prior)
        local fresh = Clip.load_row(args.clip_id)
        command:set_parameter("__timeline_mutations", {
            sequence_id = args.sequence_id,
            inserts = {}, deletes = {},
            updates = { {
                clip_id        = args.clip_id,
                sequence_start = fresh.sequence_start_frame,
                duration       = fresh.duration_frames,
                source_in      = fresh.source_in_frame,
                source_out     = fresh.source_out_frame,
            } },
        })
        return true
    end

    command_undoers["Slip"] = function(command)
        local args = command:get_all_parameters()
        local prior = args.prior_state
        assert(prior, "Undo Slip: prior_state missing")
        Clip.update_bounds(args.clip_id,
            prior.sequence_start_frame, prior.duration_frames,
            prior.source_in_frame, prior.source_out_frame)
        return true
    end

    return {
        executor = command_executors["Slip"],
        undoer   = command_undoers["Slip"],
        spec     = SPEC,
    }
end

return M
