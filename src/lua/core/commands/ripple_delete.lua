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
--   - clips on the same track with timeline_start >= deleted_clip.end
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
-- shares its link group. Returns a list of {id, track_id, timeline_start,
-- duration} captured BEFORE any DB mutation.
local function gather_delete_unit(primary_clip)
    local unit = { {
        id             = primary_clip.id,
        track_id       = primary_clip.track_id,
        timeline_start = primary_clip.timeline_start_frame,
        duration       = primary_clip.duration_frames,
    } }
    local group_id = ClipLink.get_link_group_id(primary_clip.id)
    if not group_id then return unit end
    local members = ClipLink.get_link_group(primary_clip.id) or {}
    for _, m in ipairs(members) do
        if m.clip_id ~= primary_clip.id then
            local row = Clip.load_v13_row(m.clip_id)
            assert(row, string.format(
                "RippleDelete: link-group member %s not found", m.clip_id))
            unit[#unit + 1] = {
                id             = row.id,
                track_id       = row.track_id,
                timeline_start = row.timeline_start_frame,
                duration       = row.duration_frames,
            }
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
    assert(database.savepoint(SAVEPOINT), "RippleDelete: savepoint failed")
    local rippled_ids = {}
    local ok, err = pcall(function()
        for _, m in ipairs(unit) do
            Clip.delete_one(m.id)
        end
        for _, m in ipairs(unit) do
            local from = m.timeline_start + m.duration
            local ids = Clip.ripple_track_forward(m.track_id, from, -m.duration)
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
        rippled_ids  = rippled_ids,
    }
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        clip_id     = { required = true },
    },
    persisted = {
        prior_unit  = {},  -- captured for redo/audit; full undo of a
        prior_ripple = {}, -- DELETE+ripple needs row-restoration which
                            -- is not part of this contract iteration.
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
        command:set_parameter("prior_unit",   result_or_err.deleted)
        command:set_parameter("prior_ripple", result_or_err.rippled_ids)
        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    command_undoers["RippleDelete"] = function(_command)
        -- TODO(T046 full): row-restoration undo. The contract test for
        -- T038 covers execute only; full undo is part of the broader
        -- delete-command sweep where we capture every clip column at
        -- delete time and re-INSERT on undo.
        error("RippleDelete: undo not yet implemented (T046 full sweep)", 0)
    end

    return {
        executor = command_executors["RippleDelete"],
        undoer   = command_undoers["RippleDelete"],
        spec     = SPEC,
    }
end

return M
