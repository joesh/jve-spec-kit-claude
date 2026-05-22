--- RippleDelete command (Feature 013, T046 partial — ripple_delete only).
--
-- Deletes a clip from a sequence and ripples downstream clips on each
-- affected track upstream by the deleted clip's duration on that track.
-- If the target clip is part of a link group, the WHOLE group is treated
-- as one delete unit (FR-003 / Acceptance Scenario 8): every linked clip
-- is removed and each track ripples independently.
--
-- Effect (per clip in the delete unit):
--   - the clip is deleted (clip_links and clip_channel_override rows
--     cascade via FK ON DELETE)
--   - clips on the same track with sequence_start >= deleted_clip.end
--     shift upstream by deleted_clip.duration
--
-- Link groups on *neighboring* (not-deleted) clips remain intact: their
-- clip_links rows are not touched.
--
-- Refuses: clip_id missing or not in args.sequence_id. Refusal is loud;
-- DB unchanged.
--
-- Atomicity: SAVEPOINT wraps deletes + ripples so any post-condition
-- violation unwinds the entire operation.
--
-- @file ripple_delete.lua

local M = {}

local Clip     = require("models.clip")
local ClipLink = require("models.clip_link")
local database = require("core.database")
local log      = require("core.logger").for_area("commands")

local SAVEPOINT = "ripple_delete_atomic"

-- Resolve the delete unit: the primary clip plus every other clip that
-- shares its link group. Each entry is a full V13 capture state so undo
-- can restore the clip exactly. Captures BEFORE any DB mutation.
local function gather_delete_unit(primary_clip)
    local unit = { Clip.capture_v13_state(primary_clip.id) }
    local group_id = ClipLink.get_link_group_id(primary_clip.id)
    if not group_id then return unit end
    local members = ClipLink.get_link_group(primary_clip.id) or {}
    for _, m in ipairs(members) do
        if m.clip_id ~= primary_clip.id then
            unit[#unit + 1] = Clip.capture_v13_state(m.clip_id)
        end
    end
    return unit
end

function M.execute(args)
    assert(type(args) == "table", "RippleDelete.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "RippleDelete: sequence_id required (rule 2.29)")
    assert(args.clip_id and args.clip_id ~= "",
        "RippleDelete: clip_id required")

    local primary = Clip.load_v13_row(args.clip_id)
    assert(primary, string.format(
        "RippleDelete: clip %s not found", args.clip_id))
    assert(primary.owner_sequence_id == args.sequence_id, string.format(
        "RippleDelete: clip %s owner=%s != sequence_id=%s",
        args.clip_id, primary.owner_sequence_id, args.sequence_id))

    local unit = gather_delete_unit(primary)

    -- Atomic: delete every member, then ripple each affected track.
    -- Order: delete first frees the track, so ripple's negative shift
    -- never tries to land a clip on top of a still-living deleted clip.
    -- Capture per-track ripple plan. Each (track_id, from_frame, shift)
    -- is replayed in reverse on undo to put downstream clips back.
    local ripple_plan = {}
    for _, captured in ipairs(unit) do
        local r = captured.row
        ripple_plan[#ripple_plan + 1] = {
            track_id   = r.track_id,
            from_frame = r.sequence_start_frame + r.duration_frames,
            shift      = -r.duration_frames,
        }
    end

    assert(database.savepoint(SAVEPOINT), "RippleDelete: savepoint failed")
    local rippled_ids = {}
    local ok, err = pcall(function()
        for _, captured in ipairs(unit) do
            Clip.delete_one(captured.row.id)
        end
        for _, p in ipairs(ripple_plan) do
            local ids = Clip.ripple_track_forward(p.track_id, p.from_frame, p.shift)
            for _, id in ipairs(ids) do rippled_ids[#rippled_ids + 1] = id end
        end
    end)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT),
        "RippleDelete: release savepoint failed")

    log.event("RippleDelete primary=%s unit=%d rippled=%d",
        args.clip_id, #unit, #rippled_ids)

    return {
        sequence_id  = args.sequence_id,
        deleted      = unit,
        ripple_plan  = ripple_plan,
        rippled_ids  = rippled_ids,
    }
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        clip_id     = { required = true },
    },
    persisted = {
        prior_unit   = {},  -- list of capture_v13_state results
        ripple_plan  = {},  -- list of {track_id, from_frame, shift}
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["RippleDelete"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("RippleDelete: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("prior_unit",  result_or_err.deleted)
        command:set_parameter("ripple_plan", result_or_err.ripple_plan)
        return true
    end

    command_undoers["RippleDelete"] = function(command)
        local args = command:get_all_parameters()
        local prior = args.prior_unit
        local plan  = args.ripple_plan
        assert(type(prior) == "table" and #prior > 0,
            "Undo RippleDelete: prior_unit missing or empty")
        assert(type(plan) == "table",
            "Undo RippleDelete: ripple_plan missing")

        -- Order matters for the video-overlap trigger:
        --   1. Re-shift downstream clips RIGHT (un-ripple) so the
        --      timeline range that the deleted clips occupied is empty.
        --   2. Re-INSERT the deleted clips into that empty range.
        -- For the un-ripple, replay each plan entry with the OPPOSITE
        -- shift; the from_frame is where the ripple originally started
        -- (i.e. sequence_end of the deleted clip), and the new positions
        -- are at from_frame + shift (a leftward shift). To undo we
        -- shift everything at >= (from_frame + shift) by -shift.
        assert(database.savepoint(SAVEPOINT), "Undo RippleDelete: savepoint failed")
        local ok, err = pcall(function()
            for _, p in ipairs(plan) do
                local current_from = p.from_frame + p.shift
                Clip.ripple_track_forward(p.track_id, current_from, -p.shift)
            end
            for _, captured in ipairs(prior) do
                Clip.restore_v13_state(captured)
            end
        end)
        if not ok then
            database.rollback_to_savepoint(SAVEPOINT)
            database.release_savepoint(SAVEPOINT)
            error(err, 0)
        end
        assert(database.release_savepoint(SAVEPOINT),
            "Undo RippleDelete: release savepoint failed")

        return true
    end

    return {
        executor = command_executors["RippleDelete"],
        undoer   = command_undoers["RippleDelete"],
        spec     = SPEC,
    }
end

return M
