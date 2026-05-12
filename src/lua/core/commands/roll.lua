--- Roll command (Feature 013, T044).
--
-- Rolls the shared edit point between two adjacent clips A (outgoing) and
-- B (incoming) on the same track by ±N owner-timebase frames. A extends
-- (or retracts) by N on its tail; B shrinks (or extends) by N on its head.
-- Each side walks the owner→source delta under its OWN fps_mismatch_policy
-- so resample and passthrough clips can sit across a roll.
--
-- Effect:
--   A.timeline_start_frame  unchanged
--   A.duration_frames       += N
--   A.source_in_frame       unchanged
--   A.source_out_frame      += owner_delta_to_source(A.policy, N, ...)
--
--   B.timeline_start_frame  += N
--   B.duration_frames       -= N
--   B.source_in_frame       += owner_delta_to_source(B.policy, N, ...)
--   B.source_out_frame      unchanged
--
-- Pre-conditions (all loud-fail, DB unchanged on refusal):
--   - delta_timeline_frames != 0
--   - A and B both on this sequence
--   - B.timeline_start == A.timeline_start + A.duration (truly adjacent)
--   - A.duration + N > 0 AND B.duration - N > 0 (neither collapses)
--   - source window is non-empty with lower bound >= 0 on both sides post-write (checked via Clip.update)
--
-- Atomicity: writes are wrapped in a SAVEPOINT so a partial roll (A succeeds,
-- B fails source-window check) leaves the DB exactly as it was before the command ran.
--
-- SQL isolation: all DB access via models.
--
-- @file roll.lua

local M = {}

local Clip     = require("models.clip")
local Sequence = require("models.sequence")
local database = require("core.database")
local log      = require("core.logger").for_area("commands")

local SAVEPOINT = "roll_atomic"

function M.execute(args)
    assert(type(args) == "table", "Roll.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "Roll: sequence_id required (rule 2.29)")
    assert(args.outgoing_clip_id and args.outgoing_clip_id ~= "",
        "Roll: outgoing_clip_id required")
    assert(args.incoming_clip_id and args.incoming_clip_id ~= "",
        "Roll: incoming_clip_id required")
    assert(args.outgoing_clip_id ~= args.incoming_clip_id,
        "Roll: outgoing and incoming must be distinct clips")
    assert(type(args.delta_timeline_frames) == "number",
        "Roll: delta_timeline_frames must be integer")
    local N = args.delta_timeline_frames
    assert(N ~= 0, "Roll: delta_timeline_frames must be non-zero")

    local a = Clip.load_v13_row(args.outgoing_clip_id)
    local b = Clip.load_v13_row(args.incoming_clip_id)
    assert(a, string.format("Roll: outgoing clip %s not found", args.outgoing_clip_id))
    assert(b, string.format("Roll: incoming clip %s not found", args.incoming_clip_id))
    assert(a.owner_sequence_id == args.sequence_id, string.format(
        "Roll: outgoing clip %s owner=%s != sequence_id=%s",
        args.outgoing_clip_id, a.owner_sequence_id, args.sequence_id))
    assert(b.owner_sequence_id == args.sequence_id, string.format(
        "Roll: incoming clip %s owner=%s != sequence_id=%s",
        args.incoming_clip_id, b.owner_sequence_id, args.sequence_id))
    assert(a.track_id == b.track_id, string.format(
        "Roll: clips must be on the same track (outgoing=%s, incoming=%s)",
        a.track_id, b.track_id))

    local a_end = a.timeline_start_frame + a.duration_frames
    assert(b.timeline_start_frame == a_end, string.format(
        "Roll: clips not adjacent — outgoing ends at %d but incoming starts at %d",
        a_end, b.timeline_start_frame))

    local new_a_duration = a.duration_frames + N
    local new_b_duration = b.duration_frames - N
    assert(new_a_duration > 0, string.format(
        "Roll: would collapse outgoing clip (duration %d + delta %d = %d)",
        a.duration_frames, N, new_a_duration))
    assert(new_b_duration > 0, string.format(
        "Roll: would collapse incoming clip (duration %d - delta %d = %d)",
        b.duration_frames, N, new_b_duration))

    local owner = Sequence.find(args.sequence_id)
    assert(owner, "Roll: owner sequence not found")
    local a_nested = Sequence.find(a.sequence_id)
    local b_nested = Sequence.find(b.sequence_id)
    assert(a_nested and b_nested,
        "Roll: outgoing or incoming nested sequence not found")

    local a_source_delta = Clip.owner_delta_to_source(
        a.fps_mismatch_policy, N,
        owner.fps_numerator,   owner.fps_denominator,
        a_nested.fps_numerator, a_nested.fps_denominator)
    local b_source_delta = Clip.owner_delta_to_source(
        b.fps_mismatch_policy, N,
        owner.fps_numerator,   owner.fps_denominator,
        b_nested.fps_numerator, b_nested.fps_denominator)

    local new_a_source_out   = a.source_out_frame + a_source_delta
    local new_b_timeline     = b.timeline_start_frame + N
    local new_b_source_in    = b.source_in_frame + b_source_delta

    if N > 0 then
        Clip.assert_within_master_coverage(a.sequence_id, new_a_source_out,
            "Roll outgoing=" .. args.outgoing_clip_id)
    end

    -- Update order matters for the video-overlap trigger: we must move the
    -- clip that's RETRACTING from the shared edge first, so the growing
    -- side never transiently overlaps the shrinking one.
    --   N > 0: A grows rightward; B retracts from its left edge → update B first.
    --   N < 0: A retracts from its right edge; B grows leftward → update A first.
    -- SAVEPOINT guarantees atomicity: if either update's source-window check raises,
    -- pcall unwinds to ROLLBACK TO SAVEPOINT, leaving DB untouched.
    local function update_a()
        Clip.update_bounds(args.outgoing_clip_id,
            a.timeline_start_frame, new_a_duration,
            a.source_in_frame, new_a_source_out)
    end
    local function update_b()
        Clip.update_bounds(args.incoming_clip_id,
            new_b_timeline, new_b_duration,
            new_b_source_in, b.source_out_frame)
    end
    assert(database.savepoint(SAVEPOINT), "Roll: savepoint failed")
    local ok, err = pcall(function()
        if N > 0 then update_b(); update_a()
        else           update_a(); update_b() end
    end)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT), "Roll: release savepoint failed")

    log.event("Roll outgoing=%s incoming=%s N=%d a_dsrc=%d b_dsrc=%d",
        args.outgoing_clip_id, args.incoming_clip_id, N,
        a_source_delta, b_source_delta)

    return {
        outgoing_clip_id = args.outgoing_clip_id,
        incoming_clip_id = args.incoming_clip_id,
        delta            = N,
        prior = {
            outgoing = {
                timeline_start_frame = a.timeline_start_frame,
                duration_frames      = a.duration_frames,
                source_in_frame      = a.source_in_frame,
                source_out_frame     = a.source_out_frame,
            },
            incoming = {
                timeline_start_frame = b.timeline_start_frame,
                duration_frames      = b.duration_frames,
                source_in_frame      = b.source_in_frame,
                source_out_frame     = b.source_out_frame,
            },
        },
    }
end

local SPEC = {
    args = {
        sequence_id           = { required = true },
        outgoing_clip_id      = { required = true },
        incoming_clip_id      = { required = true },
        delta_timeline_frames = { required = true },
    },
    persisted = {
        prior_state = {},
    },
}

local function emit_mutations(command, args)
    local a = Clip.load_v13_row(args.outgoing_clip_id)
    local b = Clip.load_v13_row(args.incoming_clip_id)
    command:set_parameter("__timeline_mutations", {
        sequence_id = args.sequence_id,
        inserts = {}, deletes = {},
        updates = {
            {
                clip_id          = args.outgoing_clip_id,
                start_value      = a.timeline_start_frame,
                duration_value   = a.duration_frames,
                source_in_value  = a.source_in_frame,
                source_out_value = a.source_out_frame,
            },
            {
                clip_id          = args.incoming_clip_id,
                start_value      = b.timeline_start_frame,
                duration_value   = b.duration_frames,
                source_in_value  = b.source_in_frame,
                source_out_value = b.source_out_frame,
            },
        },
    })
end

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["Roll"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("Roll: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("prior_state", result_or_err.prior)
        emit_mutations(command, args)
        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    command_undoers["Roll"] = function(command)
        local args = command:get_all_parameters()
        local prior = args.prior_state
        assert(prior and prior.outgoing and prior.incoming,
            "Undo Roll: prior_state missing outgoing/incoming")
        -- Same ordering rule as execute: the side RETRACTING from the
        -- shared edge writes first so no transient video overlap trips
        -- the schema trigger. The undo direction is inferred from the
        -- prior vs. current outgoing-clip duration.
        local cur_a = Clip.load_v13_row(args.outgoing_clip_id)
        local restore_a = function()
            Clip.update_bounds(args.outgoing_clip_id,
                prior.outgoing.timeline_start_frame, prior.outgoing.duration_frames,
                prior.outgoing.source_in_frame, prior.outgoing.source_out_frame)
        end
        local restore_b = function()
            Clip.update_bounds(args.incoming_clip_id,
                prior.incoming.timeline_start_frame, prior.incoming.duration_frames,
                prior.incoming.source_in_frame, prior.incoming.source_out_frame)
        end
        assert(database.savepoint(SAVEPOINT), "Undo Roll: savepoint failed")
        local ok, err = pcall(function()
            if prior.outgoing.duration_frames > cur_a.duration_frames then
                -- Undo grows A → B must retract first.
                restore_b(); restore_a()
            else
                -- Undo shrinks A → A retracts first.
                restore_a(); restore_b()
            end
        end)
        if not ok then
            database.rollback_to_savepoint(SAVEPOINT)
            database.release_savepoint(SAVEPOINT)
            error(err, 0)
        end
        assert(database.release_savepoint(SAVEPOINT), "Undo Roll: release savepoint failed")
        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    return {
        executor = command_executors["Roll"],
        undoer   = command_undoers["Roll"],
        spec     = SPEC,
    }
end

return M
