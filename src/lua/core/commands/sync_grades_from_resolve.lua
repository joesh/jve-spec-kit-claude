--- SyncGradesFromResolve — pull grades back from Resolve into JVE
--- (spec 023, T031, FR-013/FR-014/FR-015/FR-017).
---
--- Three entry points:
---   M.apply(response, db, synced_at)
---       Pure data path: takes the helper's `read_grades` result, upserts
---       clip_grade rows for matched clips, updates the identity_ledger
---       grade_fingerprint, returns a captured-state table for undo.
---   M.restore(captured, db)
---       Reverts the rows apply() touched: re-upserts the prior grade
---       row for clips that had one; deletes the row for clips that
---       didn't. Idempotent against further state.
---   M.execute(args, on_complete)
---       Full command: pulls via helper_supervisor → applies → invokes
---       on_complete with success / structured error.
---
--- This separation makes apply()/restore() unit-testable without the
--- helper running (T030), while M.execute is integration-level (T034 once
--- T029 lands). FR-022 — no mocks; tests pass real data structures.

local M = {}

local ClipGrade       = require("models.clip_grade")
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local supervisor      = require("core.resolve_bridge.helper_supervisor")
local log             = require("core.logger").for_area("commands")

local function load_existing_row(clip_id, db)
    return ClipGrade.load(clip_id, db)
end

local function delete_grade(clip_id, db)
    local stmt = assert(db:prepare(
        "DELETE FROM clip_grade WHERE clip_id = ?"),
        "sync_grades: prepare DELETE failed")
    stmt:bind_value(1, clip_id)
    local ok = stmt:exec()
    stmt:finalize()
    assert(ok, "sync_grades: DELETE failed for clip " .. clip_id)
end

local function assert_response_shape(response)
    assert(type(response) == "table" and type(response.grades) == "table",
        "sync_grades.apply: response.grades array required")
    for i, row in ipairs(response.grades) do
        assert(type(row.jve_guid) == "string" and row.jve_guid ~= "",
            string.format("sync_grades.apply: grade[%d] missing jve_guid",
                i))
        assert(type(row.fidelity) == "string",
            string.format("sync_grades.apply: grade[%d] missing fidelity",
                i))
    end
end

local function new_grade_from_response_row(row, synced_at)
    return {
        cdl       = row.cdl,           -- may be nil (non-primary fidelity)
        lut_ref   = row.lut and row.lut.ref,
        fidelity  = row.fidelity,
        source    = "resolve",
        stale     = 0,
        synced_at = synced_at,
    }
end

--- Apply a helper read_grades response. Returns a captured table that
--- restore() consumes to undo the change.
function M.apply(response, db, synced_at)
    assert_response_shape(response)
    assert(db, "sync_grades.apply: db required")
    assert(type(synced_at) == "number" and synced_at >= 0,
        "sync_grades.apply: synced_at unix timestamp required")

    local captured = { entries = {} }
    for _, row in ipairs(response.grades) do
        local clip_id = row.jve_guid
        local before = load_existing_row(clip_id, db)
        captured.entries[#captured.entries + 1] = {
            clip_id = clip_id,
            before  = before,  -- nil if clip had no grade
        }
        local new_grade = new_grade_from_response_row(row, synced_at)
        ClipGrade.upsert(clip_id, new_grade, db)

        -- Update ledger fingerprint so subsequent SyncGrades can detect
        -- whether Resolve drifted vs JVE-local edits (FR-025).
        local existing_link = identity_ledger.load(clip_id, db)
        if existing_link then
            identity_ledger.upsert(clip_id, {
                resolve_item_id   = existing_link.resolve_item_id,
                grade_fingerprint = ClipGrade.fingerprint(new_grade),
                edit_fingerprint  = existing_link.edit_fingerprint,
            }, db)
        end
    end
    log.event("SyncGradesFromResolve.apply: %d grade(s) synced",
        #response.grades)
    return captured
end

--- Restore the state captured by apply().
function M.restore(captured, db)
    assert(type(captured) == "table"
        and type(captured.entries) == "table",
        "sync_grades.restore: captured.entries required")
    assert(db, "sync_grades.restore: db required")

    for _, entry in ipairs(captured.entries) do
        if entry.before == nil then
            delete_grade(entry.clip_id, db)
        else
            ClipGrade.upsert(entry.clip_id, entry.before, db)
        end
    end
    log.event("SyncGradesFromResolve.restore: %d grade(s) reverted",
        #captured.entries)
end

--- Full command path: pulls grades from helper, applies them, fires
--- on_complete. Non-blocking — on_complete carries success/error.
function M.execute(args)
    assert(type(args) == "table", "SyncGradesFromResolve: args required")
    assert(type(args.on_complete) == "function",
        "SyncGradesFromResolve: on_complete callback required")
    assert(args.item_ids == nil or type(args.item_ids) == "table",
        "SyncGradesFromResolve: item_ids must be array if present")

    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "SyncGradesFromResolve: no database connection")

    local client, err = supervisor.ensure_client()
    if not client then
        args.on_complete(nil, "helper_unavailable", err)
        return
    end

    local helper_args = {}
    if args.item_ids then helper_args.item_ids = args.item_ids end
    client:request("read_grades", helper_args,
        function(response, code, message)
            if response == nil then
                args.on_complete(nil, code, message)
                return
            end
            local ok, captured_or_err = pcall(M.apply,
                response.result, db, os.time())
            if not ok then
                args.on_complete(nil, "resolve_api_error",
                    tostring(captured_or_err))
                return
            end
            args.on_complete({
                applied_count = #response.result.grades,
                captured = captured_or_err,
            }, nil, nil)
        end)
end

local SPEC = {
    undoable      = true,
    mutates_clips = false,  -- mutates clip_grade, not clips table
    args = {
        item_ids    = { required = false, kind = "table" },
        on_complete = { required = true,  kind = "function" },
    },
}

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["SyncGradesFromResolve"] = function(command)
        local args = command:get_all_parameters()
        local ok, err = pcall(M.execute, args)
        if not ok then
            set_last_error("SyncGradesFromResolve: " .. tostring(err))
            return false, tostring(err)
        end
        return true
    end
    command_undoers["SyncGradesFromResolve"] = function(command)
        local args = command:get_all_parameters()
        if args.captured then
            local database = require("core.database")
            M.restore(args.captured, database.get_connection())
        end
        return true
    end
    return {
        executor = command_executors["SyncGradesFromResolve"],
        undoer   = command_undoers["SyncGradesFromResolve"],
        spec     = SPEC,
    }
end

return M
