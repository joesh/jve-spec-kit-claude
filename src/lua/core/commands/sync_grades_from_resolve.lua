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
local lut_identity      = require("core.lut_identity")
local Sequence          = require("models.sequence")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local discovery         = require("core.resolve_bridge.discovery")
local supervisor        = require("core.resolve_bridge.helper_supervisor")
local bridge_command    = require("core.commands.bridge_command")
local Signals           = require("core.signals")
local log               = require("core.logger").for_area("commands")

-- LUT bake cache root. Per-project subdir keeps bakes scoped to the
-- project that produced them; survives JVE relaunches; cheap to GC by
-- removing files whose `resolve_item_id` is no longer in the live
-- timeline (not yet implemented — see memory todo).
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
-- a Lua-side join through `identity_ledger` (populated by the
-- sync-time auto-discovery's positional or marker-channel match per
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

-- Wire-boundary validation for a single read_grades item. Returns nil on
-- valid, or an error string on invalid. Belongs here so M.apply's
-- assert_response_shape can be a true internal invariant guard.
-- Callers MUST log.warn on error — never crash on wire data (rule 1.14).
local function validate_grade_wire_item(row, i)
    if type(row.resolve_item_id) ~= "string" or row.resolve_item_id == "" then
        return string.format(
            "sync_grades.apply: grade[%d] missing resolve_item_id", i)
    end
    if not FIDELITIES[row.fidelity] then
        return string.format(
            "sync_grades.apply: grade[%d] fidelity %q not in closed "
            .. "set {primary, partial, unrepresentable, none}",
            i, tostring(row.fidelity))
    end
    -- cdl is gated on fidelity=="primary" (FR-015 honest, never
    -- approximated). Validate CDL structure here so cdl_wire_to_model
    -- can assert as an internal invariant.
    if row.fidelity == "primary" then
        if type(row.cdl) ~= "table" then
            return string.format(
                "sync_grades.apply: grade[%d] fidelity=primary "
                .. "requires cdl table", i)
        end
        for _, name in ipairs({"slope", "offset", "power"}) do
            local t = row.cdl[name]
            if type(t) ~= "table" or #t ~= 3 then
                return string.format(
                    "sync_grades.apply: grade[%d].cdl.%s must be "
                    .. "3-element array, got %s", i, name, type(t))
            end
            for j = 1, 3 do
                if type(t[j]) ~= "number" then
                    return string.format(
                        "sync_grades.apply: grade[%d].cdl.%s[%d] "
                        .. "must be number, got %s",
                        i, name, j, type(t[j]))
                end
            end
        end
        if type(row.cdl.sat) ~= "number" then
            return string.format(
                "sync_grades.apply: grade[%d].cdl.sat must be "
                .. "number, got %s", i, type(row.cdl.sat))
        end
    elseif row.cdl ~= nil then
        return string.format(
            "sync_grades.apply: grade[%d] fidelity=%q must not "
            .. "carry cdl (FR-015 honest downgrade)",
            i, row.fidelity)
    end
    -- lut is optional; when present must be {ref: non-empty string}
    if row.lut ~= nil then
        if type(row.lut) ~= "table" then
            return string.format(
                "sync_grades.apply: grade[%d].lut must be table, got %s",
                i, type(row.lut))
        end
        if type(row.lut.ref) ~= "string" or row.lut.ref == "" then
            return string.format(
                "sync_grades.apply: grade[%d].lut.ref must be "
                .. "non-empty string, got %s",
                i, type(row.lut.ref))
        end
    end
    return nil
end

-- Internal invariant guard — wire validation is done by
-- validate_grade_wire_item before items reach this point.
local function assert_response_shape(response)
    assert(type(response) == "table" and type(response.grades) == "table",
        "sync_grades.apply: response.grades array required")
end

-- Translate the helper-protocol §read_grades WIRE CDL shape
--   { slope:[r,g,b], offset:[r,g,b], power:[r,g,b], sat: float }
-- into JVE's clip_grade MODEL shape
--   { slope_r, slope_g, slope_b, offset_r, offset_g, offset_b,
--     power_r, power_g, power_b, saturation }
-- Internal invariant asserts only — wire CDL structure is validated by
-- validate_grade_wire_item before any item reaches this function.
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

-- Build a clip_grade model row from a wire grade row. The `reproduction`
-- axis (FR-015 — what JVE can DISPLAY) is computed here because it is the
-- only stage that has both the fidelity and the BAKED cube on disk: a
-- spatial Resolve grade is `unrepresentable` yet bakes to an identity LUT,
-- so the cube content — not the fidelity alone — decides whether the clip
-- shows the grade ('approximate') or passthrough ('not_shown'). The cube
-- read is one-time-per-clip-per-sync and early-outs on the first graded
-- grid point. A missing cube asserts (lut_identity) — a bake-pipeline
-- inconsistency, not a "maybe".
local function new_grade_from_response_row(row, row_index, synced_at)
    local lut_ref = row.lut and row.lut.ref
    local lut_is_identity = nil
    if lut_ref ~= nil then
        lut_is_identity = lut_identity.is_identity(lut_ref)
    end
    return {
        cdl          = row.cdl and cdl_wire_to_model(row.cdl, row_index)
                                or nil,
        lut_ref      = lut_ref,
        fidelity     = row.fidelity,
        reproduction = ClipGrade.classify_reproduction(
            row.fidelity, lut_ref, lut_is_identity),
        source       = "resolve",
        stale        = 0,
        synced_at    = synced_at,
    }
end

-- FR-013a stale walk: any ledger-linked clip in `sequence_id` whose
-- Resolve item was absent from the read_grades response keeps its
-- last-synced grade but is marked stale=1. Captures the prior row so
-- restore() can revert.
local function walk_ledger_for_stale(sequence_id, seen_clip_ids, db,
                                      captured)
    -- Rule 2.5: Use centralized iterator for sequence links (review item #1).
    local links = identity_ledger.iter_links_for_sequence(sequence_id, db)
    for _, link in ipairs(links) do
        local clip_id = link.clip_id
        if seen_clip_ids[clip_id] == nil then
            local before = load_existing_row(clip_id, db)
            if before ~= nil and before.stale == 0 then
                captured.entries[#captured.entries + 1] = {
                    clip_id = clip_id,
                    before  = before,
                }
                local staled = {
                    cdl          = before.cdl,
                    lut_ref      = before.lut_ref,
                    fidelity     = before.fidelity,
                    reproduction = before.reproduction,
                    source       = before.source,
                    stale        = 1,
                    synced_at    = before.synced_at,
                }
                ClipGrade.upsert(clip_id, staled, db)
            end
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

    -- Wire-boundary filter: drop malformed items with log.warn so the
    -- rest of apply can assert internal invariants without crashing on
    -- bad external data (rule 1.14 / rule 2.32).
    local valid_grades = {}
    for i, row in ipairs(response.grades) do
        local field_err = validate_grade_wire_item(row, i)
        if field_err ~= nil then
            log.warn(field_err)
        else
            valid_grades[#valid_grades + 1] = row
        end
    end

    local captured = {
        entries                 = {},
        unmatched_resolve_items = {},
        -- Carrier-less grades: fidelity partial/unrepresentable with
        -- no lut_ref — view_grade_pull returns nil for these, so the
        -- clip displays UNGRADED despite a grade existing in Resolve.
        -- Normal cause: the Resolve-side LUT bake failed (e.g. the
        -- user left the Color page mid-bake — 2026-06-10 incident:
        -- 623 clips silently affected). Counted here, warned below.
        no_carrier_count        = 0,
    }
    local seen_clip_ids = {}
    for i, row in ipairs(valid_grades) do
        -- Ledger-driven attribution (FR-021): helper emits its native
        -- resolve_item_id; JVE owns the join to clip.id. The ledger is
        -- populated by the auto-discovery that ran at the start of
        -- this same sync (positional per FR-011c, or by marker). A row
        -- whose resolve_item_id has no ledger entry is REPORTED, not
        -- silently dropped — symmetric with the FR-011c unmatched-JVE-
        -- clip discipline. Typical cause: a Resolve item with no JVE
        -- counterpart at its position (colorist-added clip whose
        -- content matches nothing in the sequence).
        local clip_id = identity_ledger.lookup_clip_id(
            row.resolve_item_id, db)
        if clip_id == nil then
            captured.unmatched_resolve_items[
                #captured.unmatched_resolve_items + 1] = row.resolve_item_id
        else
            seen_clip_ids[clip_id] = true
            local before      = load_existing_row(clip_id, db)
            local link_before = identity_ledger.load(clip_id, db)
            assert(link_before, string.format(
                "sync_grades.apply: lookup_clip_id %q→%q but "
                .. "load(%q) returned nil — identity_ledger "
                .. "consistency violation",
                row.resolve_item_id, clip_id, clip_id))
            captured.entries[#captured.entries + 1] = {
                clip_id     = clip_id,
                before      = before,       -- nil if clip had no grade
                link_before = link_before,  -- for ledger revert on undo
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
                -- identity_ledger.upsert preserves existing
                -- grade_fingerprint when the key is omitted; passing
                -- "<none>" explicitly records the ungraded baseline
                -- so the next sync's drift detection is right.
                identity_ledger.upsert(clip_id, {
                    resolve_item_id   = link_before.resolve_item_id,
                    grade_fingerprint = UNGRADED_FINGERPRINT,
                    edit_fingerprint  = link_before.edit_fingerprint,
                }, db)
            else
                local new_grade = new_grade_from_response_row(row, i, synced_at)
                if new_grade.fidelity ~= "primary"
                        and new_grade.lut_ref == nil then
                    captured.no_carrier_count =
                        captured.no_carrier_count + 1
                end
                ClipGrade.upsert(clip_id, new_grade, db)

                -- Update ledger fingerprint so subsequent SyncGrades can
                -- detect whether Resolve drifted vs JVE-local edits (FR-025).
                identity_ledger.upsert(clip_id, {
                    resolve_item_id   = link_before.resolve_item_id,
                    grade_fingerprint = ClipGrade.fingerprint(new_grade),
                    edit_fingerprint  = link_before.edit_fingerprint,
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
    --   unmatched    = helper rows with no ledger entry even after this
    --                  sync's auto-discovery (Resolve item matches no
    --                  JVE clip by marker or position/content).
    local applied      = #valid_grades - #captured.unmatched_resolve_items
    local stale_marked = #captured.entries - applied
    log.event("SyncGradesFromResolve.apply: %d grade(s) applied, "
        .. "%d stale-marked, %d unmatched resolve_item_id(s)",
        applied, stale_marked, #captured.unmatched_resolve_items)
    -- warn (default-visible), not event: each of these clips has a
    -- grade in Resolve but displays UNGRADED in JVE — user-visible
    -- damage that was silent in the 2026-06-10 incident (623 clips).
    if captured.no_carrier_count > 0 then
        log.warn("SyncGradesFromResolve.apply: %d grade(s) have no "
            .. "displayable carrier (LUT bake failed Resolve-side?) — "
            .. "those clips display ungraded; re-run Sync Grades with "
            .. "Resolve left undisturbed during the bake",
            captured.no_carrier_count)
    end

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
        -- Revert ledger fingerprint alongside the grade row so the next
        -- SyncGrades compares against the correct pre-apply baseline.
        -- stale-walk entries (no ledger write in apply) have no link_before.
        if entry.link_before ~= nil then
            identity_ledger.upsert(entry.clip_id, {
                resolve_item_id   = entry.link_before.resolve_item_id,
                grade_fingerprint = entry.link_before.grade_fingerprint,
                edit_fingerprint  = entry.link_before.edit_fingerprint,
            }, db)
        end
    end
    log.event("SyncGradesFromResolve.restore: %d grade(s) reverted",
        #captured.entries)

    -- Symmetric to apply(): undo of a sync rewinds clip_grade rows; the
    -- View pulls from those rows, so notify it (FR-016 / FR-017).
    Signals.emit("grades_changed", captured.sequence_id)
end

-- Forward declaration: defined after execute() (below), called from
-- within execute's inner closure. Local must be visible at the closure's
-- parse site.
local request_and_apply_grades

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

    -- Progress broadcast (FR-016): the bake+pull runs minutes on a large
    -- timeline. Tell the view a sync started so the monitor can show
    -- "Syncing…" — the on-screen look is provisional until completion. The
    -- matching clear is the `sync_grades_from_resolve_completed` signal
    -- (fires on success AND error via bridge_completion.notify).
    Signals.emit("grade_sync_started", args.sequence_id)

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
        -- Auto-discovery (FR-011c): establish/repair the ledger join
        -- BEFORE pulling grades, so a freshly-imported project (or one
        -- where the colorist added clips Resolve-side) syncs without a
        -- separate user-run connect step. Read-only on Resolve,
        -- idempotent on the ledger. A rate mismatch skips only the
        -- position channel (marker matches + already-persisted links
        -- still join grades correctly) — surfaced, then the sync
        -- proceeds.
        discovery.discover_and_link(client, args.sequence_id, db,
            function(report, dcode, dmessage)
                if report == nil then
                    notify(args, nil, dcode, dmessage)
                    return
                end
                discovery.log_discovery_warnings(
                    report, "SyncGradesFromResolve")
                request_and_apply_grades(client, args, report, db,
                    command, bake_lut_dir)
            end)
    end)
end

-- Second half of the sync: read_grades → apply → notify. Split out so
-- execute() reads as the algorithm it is (discover → pull → apply).
-- `report` is discovery's result, folded into the notify payload so
-- callers see what got (un)linked alongside what got applied.
request_and_apply_grades = function(client, args, report, db, command,
                                    bake_lut_dir)
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
            --
            -- Helper anomaly channel (helper-protocol.md
            -- §read_grades `warnings`): bake/page anomalies that
            -- didn't fail the verb but leave user-visible damage
            -- (clips without a grade carrier, Resolve stuck on the
            -- Color page). Logged at warn so they're visible at
            -- default log level — stderr-only proved invisible in
            -- the 2026-06-10 incident. Missing field = version skew
            -- (helper predates this protocol); surface as structured
            -- error so the user can restart JVE to respawn the helper.
            if type(response.result.warnings) ~= "table" then
                notify(args, nil, "version_skew",
                    "read_grades response has no warnings array — "
                    .. "helper process predates this protocol; "
                    .. "restart JVE to respawn the helper")
                return
            end
            for _, w in ipairs(response.result.warnings) do
                log.warn("read_grades: %s", w)
            end
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
                -- What auto-discovery (FR-011c) just (un)linked — the
                -- counterpart of applied_count for identity. Callers
                -- and tests see matching outcomes per-sync instead of
                -- via a separate connect command's result.
                discovery               = {
                    matched        = report.matched,
                    already_linked = report.already_linked,
                    unmatched      = report.unmatched,
                    ambiguous      = report.ambiguous,
                    audio_skipped  = report.audio_skipped,
                    rate_mismatch  = report.rate_mismatch,
                    stamped        = report.stamped,
                    stamp_skipped  = report.stamp_skipped,
                    stamp_failures = report.stamp_failures,
                },
            }, nil, nil)
        end,
        { timeout_ms = BAKE_REQUEST_TIMEOUT_MS })
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
