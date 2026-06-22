--- Slide command (Feature 013, T044).
--
-- Slides a clip's position on the owner timeline by ±N owner-timebase
-- frames. The window (source_in, source_out) is unchanged; only where the
-- clip sits on the timeline moves.
--
-- Effect on the clip row:
--   sequence_start_frame  += delta_timeline_frames
--   duration_frames       unchanged
--   source_in_frame       unchanged
--   source_out_frame      unchanged
--
-- delta_timeline_frames is in owner-sequence timebase.
--
-- This file does NOT ripple adjacent clips (contracts/commands.md §Slide
-- notes that lives alongside the multi-clip ripple command set — T046).
-- What Slide here guarantees is the core mutation on the clip itself: the
-- window stays put in media-space; the clip moves in edit-space.
--
-- Refuses: delta == 0, or a slide that drags sequence_start below 0.
-- Refusal is loud; DB unchanged.
--
-- SQL isolation: all DB access via models.
--
-- @file slide.lua

local M = {}

local Clip = require("models.clip")
local log  = require("core.logger").for_area("commands")

function M.execute(args)
    assert(type(args) == "table", "Slide.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "Slide: sequence_id required (rule 2.29)")
    assert(args.clip_id and args.clip_id ~= "",
        "Slide: clip_id required")
    assert(type(args.delta_timeline_frames) == "number",
        "Slide: delta_timeline_frames must be integer")
    local delta = args.delta_timeline_frames
    assert(delta ~= 0, "Slide: delta_timeline_frames must be non-zero")

    local clip = Clip.load_row(args.clip_id)
    assert(clip, string.format("Slide: clip %s not found", args.clip_id))
    assert(clip.owner_sequence_id == args.sequence_id, string.format(
        "Slide: clip %s owner_sequence_id=%s != args.sequence_id=%s",
        args.clip_id, clip.owner_sequence_id, args.sequence_id))

    local new_sequence_start = clip.sequence_start_frame + delta
    assert(new_sequence_start >= 0, string.format(
        "Slide: new sequence_start_frame=%d < 0 (delta=%d, was=%d)",
        new_sequence_start, delta, clip.sequence_start_frame))

    Clip.update_bounds(args.clip_id,
        new_sequence_start, clip.duration_frames,
        clip.source_in_frame, clip.source_out_frame)

    log.event("Slide clip=%s delta=%d", args.clip_id, delta)

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
        sequence_id           = { required = true },
        clip_id               = { required = true },
        delta_timeline_frames = { required = true },
    },
    persisted = {
        prior_state = {},
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Slide"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Slide: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("prior_state", result_or_err.prior)
        local fresh = Clip.load_row(args.clip_id)
        command:set_parameter("__timeline_mutations", {
            sequence_id = args.sequence_id,
            inserts = {}, deletes = {},
            updates = { {
                clip_id          = args.clip_id,
                start_value      = fresh.sequence_start_frame,
                duration_value   = fresh.duration_frames,
                source_in_value  = fresh.source_in_frame,
                source_out_value = fresh.source_out_frame,
            } },
        })
        return true
    end

    command_undoers["Slide"] = function(command)
        local args = command:get_all_parameters()
        local prior = args.prior_state
        assert(prior, "Undo Slide: prior_state missing")
        Clip.update_bounds(args.clip_id,
            prior.sequence_start_frame, prior.duration_frames,
            prior.source_in_frame, prior.source_out_frame)
        return true
    end

    return {
        executor = command_executors["Slide"],
        undoer   = command_undoers["Slide"],
        spec     = SPEC,
    }
end

return M
