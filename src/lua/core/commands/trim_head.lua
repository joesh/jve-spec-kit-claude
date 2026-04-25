--- TrimHead command (Feature 013, rewrite per T043).
--
-- Trims the START of a clip's window by N owner-timebase frames.
-- Effect on the clip row:
--   timeline_start_frame  += N
--   duration_frames       -= N
--   source_in_frame       += owner_delta_to_source(policy, N, ...)
--   source_out_frame      unchanged
--
-- N is in OWNER (edit sequence) frames — the user clicks an edit-timeline
-- boundary. The source shift is derived under the clip's own
-- fps_mismatch_policy so resample and passthrough clips both behave
-- correctly.
--
-- Refuses: N <= 0, N >= duration_frames, or any trim that would collapse
-- the source window (INV-4 post-check). Refusal is loud; DB unchanged.
--
-- Ripple-variant lives in T046 (ripple_trim.lua); this plain TrimHead
-- does NOT shift downstream clips.
--
-- SQL isolation: all DB access via models.
--
-- @file trim_head.lua

local M = {}

local Clip     = require("models.clip")
local Sequence = require("models.sequence")
local log      = require("core.logger").for_area("commands")

function M.execute(args)
    assert(type(args) == "table", "TrimHead.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "TrimHead: sequence_id required (rule 2.29)")
    assert(args.clip_id and args.clip_id ~= "",
        "TrimHead: clip_id required")
    assert(type(args.trim_amount_frames) == "number",
        "TrimHead: trim_amount_frames must be integer")
    local N = args.trim_amount_frames
    assert(N > 0, string.format(
        "TrimHead: trim_amount_frames must be positive (got %d)", N))

    local clip = Clip.load_v13_row(args.clip_id)
    assert(clip, string.format("TrimHead: clip %s not found", args.clip_id))
    assert(clip.owner_sequence_id == args.sequence_id, string.format(
        "TrimHead: clip %s owner_sequence_id=%s != args.sequence_id=%s",
        args.clip_id, clip.owner_sequence_id, args.sequence_id))
    assert(N < clip.duration_frames, string.format(
        "TrimHead: trim_amount_frames (%d) must be less than clip duration (%d)",
        N, clip.duration_frames))

    local owner  = Sequence.find(args.sequence_id)
    local nested = Sequence.find(clip.nested_sequence_id)
    assert(owner and nested, "TrimHead: owner or nested sequence not found")

    local source_delta = Clip.owner_delta_to_source(
        clip.fps_mismatch_policy, N,
        owner.fps_numerator,  owner.fps_denominator,
        nested.fps_numerator, nested.fps_denominator)

    local new_timeline_start = clip.timeline_start_frame + N
    local new_duration       = clip.duration_frames - N
    local new_source_in      = clip.source_in_frame + source_delta
    -- source_out unchanged; Clip.update asserts INV-4 post-write.

    Clip.update_bounds(args.clip_id,
        new_timeline_start, new_duration,
        new_source_in, clip.source_out_frame)

    log.event("TrimHead clip=%s N=%d source_delta=%d",
        args.clip_id, N, source_delta)

    return {
        clip_id        = args.clip_id,
        trim_amount    = N,
        source_delta   = source_delta,
        prior          = {
            timeline_start_frame = clip.timeline_start_frame,
            duration_frames      = clip.duration_frames,
            source_in_frame      = clip.source_in_frame,
            source_out_frame     = clip.source_out_frame,
        },
    }
end

local SPEC = {
    args = {
        sequence_id        = { required = true },
        clip_id            = { required = true },
        trim_amount_frames = { required = true },
    },
    persisted = {
        prior_state = {},
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["TrimHead"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("TrimHead: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("prior_state", result_or_err.prior)
        -- Minimal __timeline_mutations for UI cache refresh.
        local fresh = Clip.load_v13_row(args.clip_id)
        command:set_parameter("__timeline_mutations", {
            sequence_id = args.sequence_id,
            inserts = {}, deletes = {},
            updates = { {
                clip_id          = args.clip_id,
                start_value      = fresh.timeline_start_frame,
                duration_value   = fresh.duration_frames,
                source_in_value  = fresh.source_in_frame,
                source_out_value = fresh.source_out_frame,
            } },
        })
        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    command_undoers["TrimHead"] = function(command)
        local args = command:get_all_parameters()
        local prior = args.prior_state
        assert(prior, "Undo TrimHead: prior_state missing")
        Clip.update_bounds(args.clip_id,
            prior.timeline_start_frame, prior.duration_frames,
            prior.source_in_frame, prior.source_out_frame)
        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    return {
        executor = command_executors["TrimHead"],
        undoer   = command_undoers["TrimHead"],
        spec     = SPEC,
    }
end

return M
