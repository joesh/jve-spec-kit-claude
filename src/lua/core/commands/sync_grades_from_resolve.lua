--- SyncGradesFromResolve — pull grades back from Resolve into JVE
--- (spec 023, T031, FR-013/FR-014/FR-015/FR-017).
---
--- Three entry points:
---   M.apply(response, sequence_id, db, synced_at)
---       Pure data path: takes the helper's `read_grades` result, upserts
---       clip_grade rows for matched clips, updates the identity_ledger
---       grade_fingerprint, AND marks any ledger-linked clip in
---       `sequence_id` whose Resolve item was absent from the response
---       with stale=1 (FR-013a — never silently cleared, never shown as
---       current). Returns a captured-state table for undo.
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

local ClipGrade         = require("models.clip_grade")
local Sequence          = require("models.sequence")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local supervisor        = require("core.resolve_bridge.helper_supervisor")
local bridge_command    = require("core.commands.bridge_command")
local Signals           = require("core.signals")
local log               = require("core.logger").for_area("commands")

-- LUT bake cache root. Per-project subdir keeps bakes scoped to the
-- project that produced them; survives JVE relaunches; cheap to GC by
-- removing files whose `resolve_item_id` is no longer in the live
-- timeline (handled by ConnectToResolveProject — separate commit).
local function bake_lut_dir_for_project(project_id)
    assert(type(project_id) == "string" and project_id ~= "",
        "bake_lut_dir_for_project: project_id required")
    local home = os.getenv("HOME")
    assert(home and home ~= "",
        "bake_lut_dir_for_project: $HOME not set")
    return home .. "/.jve/resolve_bake/" .. project_id
end

local OP = bridge_command.declare(
    "SyncGradesFromResolve", "sync_grades_from_resolve_completed")
local notify = OP.notify

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

-- Helper response row shape (post-FR-021 architectural fix): keyed on
-- the helper's NATIVE id (`resolve_item_id`), NOT on jve_guid. The
-- helper holds no JVE state (FR-021); attribution to a JVE clip_id is
-- a Lua-side join through `identity_ledger` (populated by
-- ConnectToResolveProject's positional or marker-channel match per
-- FR-011c). See helper-protocol.md §read_grades.
--
-- fidelity closed set: primary | partial | unrepresentable | none.
-- "none" — Resolve item is PRESENT but observed to have no CDL block
-- AND no LUT AND no non-CDL tools. Distinct from FR-013a item-absent
-- (row omitted from response). Apply DROPS any prior clip_grade row
-- for the matched clip (FR-014 re-sync overwrite).
local FIDELITIES = {
    primary = true, partial = true,
    unrepresentable = true, none = true,
}

-- Ledger grade_fingerprint sentinel for fidelity=="none". Distinct from
-- nil (which would preserve the existing fingerprint per ledger.upsert's
-- omit-means-preserve contract) AND distinct from any CDL fingerprint
-- (which is a hex digest, never "<…>" shaped). Drift detection compares
-- stored vs current fingerprint; "<none>" lets a removed-then-re-added
-- Resolve grade trip the drift bit.
local UNGRADED_FINGERPRINT = "<ungraded>"
local function assert_response_shape(response)
    assert(type(response) == "table" and type(response.grades) == "table",
        "sync_grades.apply: response.grades array required")
    for i, row in ipairs(response.grades) do
        assert(type(row.resolve_item_id) == "string"
                and row.resolve_item_id ~= "",
            string.format(
                "sync_grades.apply: grade[%d] missing resolve_item_id",
                i))
        assert(FIDELITIES[row.fidelity], string.format(
            "sync_grades.apply: grade[%d] fidelity %q not in closed "
            .. "set {primary, partial, unrepresentable, none}",
            i, tostring(row.fidelity)))
        -- cdl is gated on fidelity=="primary" (FR-015 honest, never
        -- approximated). Reject malformed combinations at the boundary.
        if row.fidelity == "primary" then
            assert(type(row.cdl) == "table", string.format(
                "sync_grades.apply: grade[%d] fidelity=primary "
                .. "requires cdl table", i))
        else
            assert(row.cdl == nil, string.format(
                "sync_grades.apply: grade[%d] fidelity=%q must not "
                .. "carry cdl (FR-015 honest downgrade)",
                i, row.fidelity))
        end
    end
end

-- Translate the helper-protocol §read_grades WIRE CDL shape
--   { slope:[r,g,b], offset:[r,g,b], power:[r,g,b], sat: float }
-- into JVE's clip_grade MODEL shape
--   { slope_r, slope_g, slope_b, offset_r, offset_g, offset_b,
--     power_r, power_g, power_b, saturation }
-- This IS the wire/model boundary; concentrating the rename in one
-- function keeps the model layer ignorant of the wire and vice versa
-- (FR-021 cleanliness). Asserts every triple has 3 numbers and sat is
-- a number — malformed input fails at the boundary (rule 1.14).
local function cdl_wire_to_model(wire, row_index)
    assert(type(wire) == "table", string.format(
        "sync_grades.apply: grade[%d].cdl must be table, got %s",
        row_index, type(wire)))
    local function check_triple(name)
        local t = wire[name]
        assert(type(t) == "table" and #t == 3, string.format(
            "sync_grades.apply: grade[%d].cdl.%s must be 3-element "
            .. "array, got %s", row_index, name, type(t)))
        for i = 1, 3 do
            assert(type(t[i]) == "number", string.format(
                "sync_grades.apply: grade[%d].cdl.%s[%d] must be number, "
                .. "got %s", row_index, name, i, type(t[i])))
        end
        return t
    end
    local slope  = check_triple("slope")
    local offset = check_triple("offset")
    local power  = check_triple("power")
    assert(type(wire.sat) == "number", string.format(
        "sync_grades.apply: grade[%d].cdl.sat must be number, got %s",
        row_index, type(wire.sat)))
    return {
        slope_r  = slope[1],  slope_g  = slope[2],  slope_b  = slope[3],
        offset_r = offset[1], offset_g = offset[2], offset_b = offset[3],
        power_r  = power[1],  power_g  = power[2],  power_b  = power[3],
        saturation = wire.sat,
    }
end

local function new_grade_from_response_row(row, row_index, synced_at)
    return {
        cdl       = row.cdl and cdl_wire_to_model(row.cdl, row_index)
                            or nil,
        lut_ref   = row.lut and row.lut.ref,
        fidelity  = row.fidelity,
        source    = "resolve",
        stale     = 0,
        synced_at = synced_at,
    }
end

-- FR-013a stale walk: any ledger-linked clip in `sequence_id` whose
-- Resolve item was absent from the read_grades response keeps its
-- last-synced grade but is marked stale=1. Captures the prior row so
-- restore() can revert.
local function walk_ledger_for_stale(sequence_id, seen_clip_ids, db,
                                      captured)
    local stmt = assert(db:prepare([[
        SELECT rbl.jve_clip_uuid
        FROM resolve_bridge_link rbl
        JOIN clips c ON c.id = rbl.jve_clip_uuid
        WHERE c.owner_sequence_id = ?
    ]]), "sync_grades.walk_ledger_for_stale: prepare failed")
    stmt:bind_value(1, sequence_id)
    if not stmt:exec() then
        stmt:finalize()
        error("sync_grades.walk_ledger_for_stale: exec failed for "
            .. "sequence " .. tostring(sequence_id))
    end
    local to_stale = {}
    while stmt:next() do
        local clip_id = stmt:value(0)
        if seen_clip_ids[clip_id] == nil then
            to_stale[#to_stale + 1] = clip_id
        end
    end
    stmt:finalize()

    for _, clip_id in ipairs(to_stale) do
        local before = load_existing_row(clip_id, db)
        if before ~= nil and before.stale == 0 then
            captured.entries[#captured.entries + 1] = {
                clip_id = clip_id,
                before  = before,
            }
            local staled = {
                cdl       = before.cdl,
                lut_ref   = before.lut_ref,
                fidelity  = before.fidelity,
                source    = before.source,
                stale     = 1,
                synced_at = before.synced_at,
            }
            ClipGrade.upsert(clip_id, staled, db)
        end
    end
end

--- Apply a helper read_grades response. Returns a captured table that
--- restore() consumes to undo the change. `sequence_id` scopes the
--- FR-013a stale walk to the sequence the call was about.
function M.apply(response, sequence_id, db, synced_at)
    assert_response_shape(response)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "sync_grades.apply: sequence_id required (FR-013a scope)")
    assert(db, "sync_grades.apply: db required")
    assert(type(synced_at) == "number" and synced_at >= 0,
        "sync_grades.apply: synced_at unix timestamp required")

    local captured = {
        entries                 = {},
        unmatched_resolve_items = {},
    }
    local seen_clip_ids = {}
    for i, row in ipairs(response.grades) do
        -- Ledger-driven attribution (FR-021): helper emits its native
        -- resolve_item_id; JVE owns the join to clip.id. Connect must
        -- have populated the ledger first (positional per FR-011c, or
        -- by marker for re-syncs). A row whose resolve_item_id has no
        -- ledger entry is REPORTED, not silently dropped — symmetric
        -- with the FR-011c unmatched-JVE-clip discipline. Typical
        -- cause: colorist added a clip in Resolve after import; user
        -- needs to re-Connect to pick it up.
        local clip_id = identity_ledger.lookup_clip_id(
            row.resolve_item_id, db)
        if clip_id == nil then
            captured.unmatched_resolve_items[
                #captured.unmatched_resolve_items + 1] = row.resolve_item_id
        else
            seen_clip_ids[clip_id] = true
            local before = load_existing_row(clip_id, db)
            captured.entries[#captured.entries + 1] = {
                clip_id = clip_id,
                before  = before,  -- nil if clip had no grade
            }

            if row.fidelity == "none" then
                -- Resolve item present + observed ungraded.
                -- FR-014 re-sync overwrite: drop any prior grade row.
                -- restore() handles before==nil (no-op) and
                -- before~=nil (re-upsert) symmetrically. Clear ledger
                -- grade_fingerprint so the next sync sees the
                -- baseline change (Resolve grade went from X to none).
                if before ~= nil then
                    delete_grade(clip_id, db)
                end
                local existing_link = identity_ledger.load(clip_id, db)
                assert(existing_link, string.format(
                    "sync_grades.apply: lookup_clip_id %q→%q but "
                    .. "load(%q) returned nil — identity_ledger "
                    .. "consistency violation",
                    row.resolve_item_id, clip_id, clip_id))
                -- identity_ledger.upsert preserves existing
                -- grade_fingerprint when the key is omitted; passing
                -- "<none>" explicitly records the ungraded baseline
                -- so the next sync's drift detection is right.
                identity_ledger.upsert(clip_id, {
                    resolve_item_id   = existing_link.resolve_item_id,
                    grade_fingerprint = UNGRADED_FINGERPRINT,
                    edit_fingerprint  = existing_link.edit_fingerprint,
                }, db)
            else
                local new_grade = new_grade_from_response_row(row, i, synced_at)
                ClipGrade.upsert(clip_id, new_grade, db)

                -- Update ledger fingerprint so subsequent SyncGrades can
                -- detect whether Resolve drifted vs JVE-local edits (FR-025).
                local existing_link = identity_ledger.load(clip_id, db)
                assert(existing_link, string.format(
                    "sync_grades.apply: lookup_clip_id %q→%q but "
                    .. "load(%q) returned nil — identity_ledger "
                    .. "consistency violation",
                    row.resolve_item_id, clip_id, clip_id))
                identity_ledger.upsert(clip_id, {
                    resolve_item_id   = existing_link.resolve_item_id,
                    grade_fingerprint = ClipGrade.fingerprint(new_grade),
                    edit_fingerprint  = existing_link.edit_fingerprint,
                }, db)
            end
        end
    end

    walk_ledger_for_stale(sequence_id, seen_clip_ids, db, captured)

    -- Stash sequence_id so restore() can emit grades_changed for the same
    -- scope without the caller having to thread it back through.
    captured.sequence_id = sequence_id

    -- Accounting (FR-011c report-not-skip discipline):
    --   applied      = response rows whose resolve_item_id is in the ledger.
    --   stale_marked = FR-013a walk added (ledger-linked clip absent from response).
    --   unmatched    = helper rows with no ledger entry (colorist added a
    --                  clip Resolve-side after import; user must re-Connect).
    local applied      = #response.grades - #captured.unmatched_resolve_items
    local stale_marked = #captured.entries - applied
    log.event("SyncGradesFromResolve.apply: %d grade(s) applied, "
        .. "%d stale-marked, %d unmatched resolve_item_id(s)",
        applied, stale_marked, #captured.unmatched_resolve_items)

    -- FR-016: the View pulls grades from model state. Until now nothing
    -- told a parked monitor that its model row changed; the next
    -- _on_show_frame only fires on playback or content_changed, so the
    -- viewer kept the pre-sync grade. Emit so subscribers can re-pull.
    Signals.emit("grades_changed", sequence_id)

    return captured
end

--- Restore the state captured by apply().
function M.restore(captured, db)
    assert(type(captured) == "table"
        and type(captured.entries) == "table",
        "sync_grades.restore: captured.entries required")
    assert(type(captured.sequence_id) == "string"
        and captured.sequence_id ~= "",
        "sync_grades.restore: captured.sequence_id required "
        .. "(apply() stashes it for the grades_changed emit)")
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

    -- Symmetric to apply(): undo of a sync rewinds clip_grade rows; the
    -- View pulls from those rows, so notify it (FR-016 / FR-017).
    Signals.emit("grades_changed", captured.sequence_id)
end

--- Full command path: pulls grades from helper, applies them, fires
--- on_complete. Non-blocking — on_complete carries success/error.
---
--- `command` is the live Command object that command_manager holds in
--- the undo stack. The async read_grades response handler persists the
--- captured-state snapshot back onto it via
--- `command:set_parameter("captured", captured)` BEFORE notify() fires
--- — without this, the undoer's args.captured is nil and undo asserts
--- (contract break, not silent no-op; see register's undoer body).
function M.execute(args, db, command)
    assert(type(args) == "table", "SyncGradesFromResolve: args required")
    assert(db, "SyncGradesFromResolve: db required (passed by "
        .. "register's executor closure; SQL isolation policy keeps "
        .. "the global DB lookup out of commands)")
    assert(command and command.set_parameter,
        "SyncGradesFromResolve: command handle required (passed by "
        .. "register_executor's closure; needed to persist captured "
        .. "state back onto the command before undo is reachable)")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SyncGradesFromResolve: sequence_id required (FR-013a scope)")
    assert(args.on_complete == nil or type(args.on_complete) == "function",
        "SyncGradesFromResolve: on_complete, when supplied, must be a "
        .. "function — terminal results also surface via the "
        .. "sync_grades_from_resolve_completed signal (FR-023).")
    assert(args.item_ids == nil or type(args.item_ids) == "table",
        "SyncGradesFromResolve: item_ids must be array if present")

    -- Look up project_id from the sequence so the LUT bake cache is
    -- per-project (~/.jve/resolve_bake/<project_id>/). Resolves sync's
    -- only-sees-sequence_id surface against the bake dir's per-project
    -- scope without making callers thread project_id through args.
    local seq = Sequence.load(args.sequence_id)
    assert(seq, "SyncGradesFromResolve: sequence not found: "
        .. args.sequence_id)
    assert(type(seq.project_id) == "string" and seq.project_id ~= "",
        "SyncGradesFromResolve: sequence missing project_id "
        .. "(schema invariant)")
    local bake_lut_dir = bake_lut_dir_for_project(seq.project_id)

    supervisor.with_client(notify, args, function(client)
        local helper_args = { bake_lut_dir = bake_lut_dir }
        if args.item_ids then helper_args.item_ids = args.item_ids end
        local sequence_id = args.sequence_id
        -- Per-request timeout: read_grades with bake_lut_dir bakes one
        -- LUT per timeline-item. t033 measured ~30 ms median per bake on
        -- Anamnesis (~1069 clips ≈ 32 s for the bake alone); add Resolve
        -- API latency for GetClipsInTimeline/EDL export and the verb
        -- comfortably runs minutes on a large project. The client-wide
        -- default request_timeout_ms (30 s, set by helper_supervisor)
        -- would trip mid-bake, then the helper's eventual reply would
        -- arrive against a cleared in-flight slot and log "unknown id".
        -- 15 minutes is sized for 30k clips at the measured rate with
        -- headroom — well above any real Anamnesis-class timeline.
        local BAKE_REQUEST_TIMEOUT_MS = 15 * 60 * 1000
        client:request("read_grades", helper_args,
            function(response, code, message)
                if response == nil then
                    notify(args, nil, code, message)
                    return
                end
                -- Async-tail asserts crash by design — see the contract
                -- documented in bridge_completion.lua (executor's pcall
                -- only catches sync-phase asserts before client:request
                -- returns; this callback runs after that pcall has
                -- popped). Masking an internal invariant violation as
                -- resolve_api_error would conflate origin (rule 2.21)
                -- and downgrade rule 1.14.
                local captured = M.apply(response.result, sequence_id, db,
                    os.time())
                -- Persist captured onto the live command so the undoer
                -- can find it. command_manager holds this same command-
                -- object reference in the undo stack; a late
                -- set_parameter from the async response handler is
                -- visible to the undoer when the user eventually presses
                -- undo. Without this, undo would hit the undoer's
                -- "args.captured required" assert (contract break per
                -- 2.13/2.32 — fail-loud is correct; a silent no-op
                -- would leave the user with a broken "undo did
                -- nothing" state).
                command:set_parameter("captured", captured)
                -- applied_count = response rows that landed on a JVE
                -- clip (via ledger). Subtract unmatched so callers see
                -- the count that actually mutated state, not the raw
                -- helper row count (which can include unmatched
                -- resolve_item_ids per FR-011c report-not-skip).
                notify(args, {
                    applied_count           = #response.result.grades
                        - #captured.unmatched_resolve_items,
                    unmatched_resolve_items = captured.unmatched_resolve_items,
                    captured                = captured,
                }, nil, nil)
            end,
            { timeout_ms = BAKE_REQUEST_TIMEOUT_MS })
    end)
end

local SPEC = {
    undoable      = true,
    mutates_clips = false,  -- mutates clip_grade, not clips table
    args = {
        sequence_id = { required = true,  kind = "string" },
        item_ids    = { required = false, kind = "table" },
        on_complete = { required = false, kind = "function" },
    },
}

function M.register(command_executors, command_undoers, db, set_last_error)
    local registered = OP.make_register(M.execute, SPEC)(
        command_executors, command_undoers, db, set_last_error)
    command_undoers[OP.op_name] = function(command)
        -- captured is produced by the async on_complete in M.execute and
        -- must be persisted onto the command before undo. A missing
        -- captured means the command was logged before apply() ran, or
        -- the framework didn't merge the on_complete result back —
        -- either is a contract break, not a silent no-op (rule 2.13/2.32).
        local args = command:get_all_parameters()
        assert(args.captured, "SyncGradesFromResolve undoer: args.captured "
            .. "required (apply() must persist captured before undo is "
            .. "reachable — see todo_sync_grades_undo_capture)")
        M.restore(args.captured, db)
        return true
    end
    return {
        executor = registered.executor,
        undoer   = command_undoers[OP.op_name],
        spec     = SPEC,
    }
end

return M
