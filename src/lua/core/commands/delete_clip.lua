--- DeleteClip command (Feature 013).
--
-- Plain (non-ripple) Delete: removes the targeted clip from the timeline
-- without shifting downstream clips on its track. Delete acts on ONLY the
-- clip(s) the user selected — a linked partner is NOT pulled in (revised
-- 2026-05-28, supersedes the original FR-003 "linked group is one delete
-- unit"). The deleted clip's clip_links row cascades away; the remaining
-- members keep their rows and stay linked among themselves.
--
-- Effect:
--   - the clip row is removed
--   - clip_links and clip_channel_override rows cascade via FK ON DELETE
--   - clips on the same track at later times stay where they are
--   - any linked partners (other clips in the group) are untouched
--
-- Refuses: clip_id missing or not in args.sequence_id; gap pseudo-ids
-- (gap clips are derived state, not deletable).
--
-- Atomicity: SAVEPOINT wraps the delete unit so a mid-delete failure
-- (e.g. a missing link group member) unwinds the entire operation.
--
-- Undo restores every captured clip via Clip.restore_state — the
-- row, its clip_channel_override rows, and its clip_links membership.
-- Atomic via SAVEPOINT so a partial restore unwinds.
--
-- @file delete_clip.lua

local M = {}

local Clip            = require("models.clip")
local database        = require("core.database")
local log             = require("core.logger").for_area("commands")
local mutation_entry  = require("core.commands._mutation_entry")

local SAVEPOINT = "delete_clip_atomic"

-- Capture the delete unit: ONLY the targeted clip. Linked partners are
-- deliberately NOT included — Delete acts on the selection alone, leaving
-- other group members in place (and linked among themselves). Returns a
-- list of full V13 capture states (row + overrides + link membership) so
-- undo restores the clip exactly, including its link-group membership.
-- Captures BEFORE any DB mutation.
local function gather_delete_unit(primary_clip)
    return { Clip.capture_state(primary_clip.id) }
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

    local primary = Clip.load_row(args.clip_id)
    assert(primary, string.format(
        "DeleteClip: clip %s not found", args.clip_id))
    assert(primary.owner_sequence_id == args.sequence_id, string.format(
        "DeleteClip: clip %s owner=%s != sequence_id=%s",
        args.clip_id, primary.owner_sequence_id, args.sequence_id))

    local unit = gather_delete_unit(primary)

    assert(database.savepoint(SAVEPOINT), "DeleteClip: savepoint failed")
    local ok, err = pcall(function()
        for _, captured in ipairs(unit) do
            Clip.delete_one(captured.row.id)
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

        -- Report mutations so command_manager downstream + UI cache invalidate.
        local bucket = {
            sequence_id = args.sequence_id,
            inserts     = {},
            updates     = {},
            deletes     = {},
            bulk_shifts = {},
        }
        for _, captured in ipairs(result_or_err.deleted) do
            bucket.deletes[#bucket.deletes + 1] = captured.row and captured.row.id or captured.id
        end
        command:set_parameter("__timeline_mutations", bucket)

        return true
    end

    command_undoers["DeleteClip"] = function(command)
        local args = command:get_all_parameters()
        local prior = args.prior_unit
        assert(type(prior) == "table" and #prior > 0,
            "Undo DeleteClip: prior_unit missing or empty")
        assert(database.savepoint(SAVEPOINT), "Undo DeleteClip: savepoint failed")
        local ok, err = pcall(function()
            for _, captured in ipairs(prior) do
                Clip.restore_state(captured)
            end
        end)
        if not ok then
            database.rollback_to_savepoint(SAVEPOINT)
            database.release_savepoint(SAVEPOINT)
            error(err, 0)
        end
        assert(database.release_savepoint(SAVEPOINT),
            "Undo DeleteClip: release savepoint failed")

        -- Report restored clips as inserts so command_manager treats undo
        -- like a real timeline mutation.
        local bucket = {
            sequence_id = args.sequence_id,
            inserts     = {},
            updates     = {},
            deletes     = {},
            bulk_shifts = {},
        }
        -- Re-read each restored clip from the DB to produce a full
        -- canonical entry for apply_inserts. An id-only stub was the old
        -- shape; consumer (normalize_clip_integers) now asserts on
        -- missing sequence_start (pre-audit-pass-5 silently skipped,
        -- leaving the cache stale relative to the DB).
        for _, captured in ipairs(prior) do
            local clip_id = captured.row and captured.row.id or captured.id
            bucket.inserts[#bucket.inserts + 1] =
                mutation_entry.build_insert_entry(clip_id, "Undo DeleteClip")
        end
        command:set_parameter("__timeline_mutations", bucket)

        return true
    end

    return {
        executor = command_executors["DeleteClip"],
        undoer   = command_undoers["DeleteClip"],
        spec     = SPEC,
    }
end

return M
