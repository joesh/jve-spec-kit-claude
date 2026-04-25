--- DeleteClip command (Feature 013, T046 partial).
--
-- Plain (non-ripple) Delete: removes a clip from the timeline without
-- shifting downstream clips on its track. Per FR-003, a linked group is
-- one unit — deleting any member removes ALL members of the group; each
-- track keeps its remaining clips at their original positions.
--
-- Effect (per clip in the delete unit):
--   - the clip row is removed
--   - clip_links and clip_channel_override rows cascade via FK ON DELETE
--   - clips on the same track at later times stay where they are
--
-- Refuses: clip_id missing or not in args.sequence_id; gap pseudo-ids
-- (gap clips are derived state, not deletable).
--
-- Atomicity: SAVEPOINT wraps the delete unit so a mid-delete failure
-- (e.g. a missing link group member) unwinds the entire operation.
--
-- Undo deferred: full row restoration (clip + overrides + link_links) is
-- a model-level concern that lands with the broader undo-capture sweep
-- in the rest of T046. The contract test exercises execute-only.
--
-- @file delete_clip.lua

local M = {}

local Clip     = require("models.clip")
local ClipLink = require("models.clip_link")
local database = require("core.database")
local log      = require("core.logger").for_area("commands")

local SAVEPOINT = "delete_clip_atomic"

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
                "DeleteClip: link-group member %s not found", m.clip_id))
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
    assert(type(args) == "table", "DeleteClip.execute: args must be table")
    assert(args.sequence_id and args.sequence_id ~= "",
        "DeleteClip: sequence_id required (rule 2.29)")
    assert(args.clip_id and args.clip_id ~= "",
        "DeleteClip: clip_id required")
    assert(not (type(args.clip_id) == "string"
                and args.clip_id:find("^gap_")), string.format(
        "DeleteClip: gap clip %s — gaps are derived state, not deletable",
        args.clip_id))

    local primary = Clip.load_v13_row(args.clip_id)
    assert(primary, string.format(
        "DeleteClip: clip %s not found", args.clip_id))
    assert(primary.owner_sequence_id == args.sequence_id, string.format(
        "DeleteClip: clip %s owner=%s != sequence_id=%s",
        args.clip_id, primary.owner_sequence_id, args.sequence_id))

    local unit = gather_delete_unit(primary)

    assert(database.savepoint(SAVEPOINT), "DeleteClip: savepoint failed")
    local ok, err = pcall(function()
        for _, m in ipairs(unit) do
            Clip.delete_one(m.id)
        end
    end)
    if not ok then
        database.rollback_to_savepoint(SAVEPOINT)
        database.release_savepoint(SAVEPOINT)
        error(err, 0)
    end
    assert(database.release_savepoint(SAVEPOINT),
        "DeleteClip: release savepoint failed")

    log.event("DeleteClip primary=%s unit=%d", args.clip_id, #unit)
    return {
        sequence_id = args.sequence_id,
        deleted     = unit,
    }
end

local SPEC = {
    args = {
        sequence_id = { required = true },
        clip_id     = { required = true },
    },
    persisted = {
        prior_unit = {},
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["DeleteClip"] = function(command)
        local args = command:get_all_parameters()
        local ok, result_or_err = pcall(M.execute, args)
        if not ok then
            set_last_error("DeleteClip: " .. tostring(result_or_err))
            return false, tostring(result_or_err)
        end
        command:set_parameter("prior_unit", result_or_err.deleted)
        local Signals = require("core.signals")
        Signals.emit("sequence_content_changed", args.sequence_id)
        return true
    end

    command_undoers["DeleteClip"] = function(_command)
        -- TODO(T046 full): row-restoration undo. Requires capturing the
        -- full clip row + clip_channel_override rows + clip_links rows
        -- at delete time, then re-INSERTing on undo.
        error("DeleteClip: undo not yet implemented (T046 full sweep)", 0)
    end

    return {
        executor = command_executors["DeleteClip"],
        undoer   = command_undoers["DeleteClip"],
        spec     = SPEC,
    }
end

return M
