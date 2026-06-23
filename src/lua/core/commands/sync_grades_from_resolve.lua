--- SyncGradesFromResolve — pull grades back from Resolve into JVE
--- (spec 023, T031, FR-013/FR-014/FR-015/FR-017).
---
--- Two entry points:
---   M.apply(response, sequence_id, db, synced_at)
---       Takes the helper's `read_grades` result, computes the per-clip
---       set/clear operations (including FR-013a stale walk for ledger-
---       linked clips absent from the response — never silently cleared,
---       never shown as current), and dispatches ONE synchronous
---       undoable `SetClipGrades` batch command covering all affected
---       clips. command_manager records a single undo entry; one Cmd-Z
---       reverts the whole sync.
---   M.execute(args, db, _command)
---       Full command: pulls via helper_supervisor → applies → invokes
---       on_complete with success / structured error.
---
--- The outer SyncGradesFromResolve command is non-undoable: undoing the
--- async outer command was the source of the original assert (a late
--- `set_parameter` on the in-memory command after the async response
--- never reached the DB-rehydrated undoer). The inner `SetClipGrades`
--- command is fully synchronous — it captures before-state for every
--- clip in the batch at execute() and command_manager persists it to
--- command_args before any undo can reach it. Mirrors
--- SyncEditsFromResolve's outer-non-undoable + inner-undoable pattern.

local M = {}

local ClipGrade         = require("models.clip_grade")
local lut_identity      = require("core.lut_identity")
local Sequence          = require("models.sequence")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local discovery         = require("core.resolve_bridge.discovery")
local supervisor        = require("core.resolve_bridge.helper_supervisor")
local bridge_command    = require("core.commands.bridge_command")
local command_manager   = require("core.command_manager")
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

-- Helper response item shape (post-FR-021 architectural fix): keyed on
-- the helper's NATIVE id (`resolve_item_id`), NOT on jve_guid. The
-- helper holds no JVE state (FR-021); attribution to a JVE clip_id is
-- a Lua-side join through `identity_ledger` (populated by the
-- sync-time auto-discovery's positional or marker-channel match per
-- FR-011c). See helper-protocol.md §read_grades.
--
-- fidelity closed set: primary | partial | unrepresentable | none.
-- "none" — Resolve item is PRESENT but observed to have no CDL block
-- AND no LUT AND no non-CDL tools. Distinct from FR-013a item-absent
-- (item omitted from response). Apply DROPS any prior clip_grade
-- entry for the matched clip (FR-014 re-sync overwrite).
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

-- FR-013a stale walk: collect operations for any ledger-linked clip in
-- `sequence_id` whose Resolve item was absent from the read_grades
-- response. The clip keeps its last-synced grade values but is marked
-- stale=1 so it's never silently shown as current. Returns ops folded
-- into the batch as action="set" with the staled grade; ledger
-- fingerprint is untouched (no new_grade_fingerprint).
local function collect_stale_walk_ops(sequence_id, seen_clip_ids, db)
    local ops = {}
    local links = identity_ledger.iter_links_for_sequence(sequence_id, db)
    for _, link in ipairs(links) do
        local clip_id = link.clip_id
        if seen_clip_ids[clip_id] == nil then
            local before = ClipGrade.load(clip_id, db)
            if before ~= nil and before.stale == 0 then
                ops[#ops + 1] = {
                    clip_id   = clip_id,
                    action    = "set",
                    new_grade = {
                        cdl          = before.cdl,
                        lut_ref      = before.lut_ref,
                        fidelity     = before.fidelity,
                        reproduction = before.reproduction,
                        source       = before.source,
                        stale        = 1,
                        synced_at    = before.synced_at,
                    },
                }
            end
        end
    end
    return ops
end

-- Filter wire response items down to those whose shape passes
-- validate_grade_wire_item. Malformed items are dropped with a log.warn
-- so the rest of apply can assert internal invariants without crashing
-- on bad external data (rule 1.14 / rule 2.32).
local function filter_valid_grades(grades)
    local valid = {}
    for i, row in ipairs(grades) do
        local field_err = validate_grade_wire_item(row, i)
        if field_err ~= nil then
            log.warn(field_err)
        else
            valid[#valid + 1] = row
        end
    end
    return valid
end

-- Translate validated wire items into per-clip ops for the SetClipGrades batch.
-- Returns ops, unmatched_resolve_items, no_carrier_count, seen_clip_ids.
-- Pure: reads ledger + existing grade rows but writes nothing.
local function plan_matched_ops(valid_grades, db, synced_at)
    local ops, unmatched = {}, {}
    local no_carrier_count = 0
    local seen_clip_ids = {}
    for i, row in ipairs(valid_grades) do
        -- Ledger-driven attribution (FR-021): helper emits its native
        -- resolve_item_id; JVE owns the join to clip.id. A row whose
        -- resolve_item_id has no ledger entry is REPORTED, not silently
        -- dropped — symmetric with FR-011c unmatched-JVE-clip discipline.
        local clip_id = identity_ledger.lookup_clip_id(
            row.resolve_item_id, db)
        if clip_id == nil then
            unmatched[#unmatched + 1] = row.resolve_item_id
        else
            seen_clip_ids[clip_id] = true
            local link_before = identity_ledger.load(clip_id, db)
            assert(link_before, string.format(
                "sync_grades.apply: lookup_clip_id %q→%q but "
                .. "load(%q) returned nil — identity_ledger "
                .. "consistency violation",
                row.resolve_item_id, clip_id, clip_id))

            if row.fidelity == "none" then
                -- FR-014 re-sync overwrite: drop any prior grade row.
                -- UNGRADED_FINGERPRINT records the ungraded baseline so
                -- the next sync's drift detection is right.
                ops[#ops + 1] = {
                    clip_id               = clip_id,
                    action                = "clear",
                    new_grade_fingerprint = UNGRADED_FINGERPRINT,
                }
            else
                local new_grade = new_grade_from_response_row(
                    row, i, synced_at)
                if new_grade.fidelity ~= "primary"
                        and new_grade.lut_ref == nil then
                    no_carrier_count = no_carrier_count + 1
                end
                ops[#ops + 1] = {
                    clip_id               = clip_id,
                    action                = "set",
                    new_grade             = new_grade,
                    -- FR-025: subsequent SyncGrades compares the stored
                    -- fingerprint against the live state to detect
                    -- Resolve-side drift vs JVE-local edits.
                    new_grade_fingerprint = ClipGrade.fingerprint(new_grade),
                }
            end
        end
    end
    return ops, unmatched, no_carrier_count, seen_clip_ids
end

--- Apply a helper read_grades response. Computes the per-clip set/clear
--- operations (matched grades + FR-013a stale walk) and dispatches them
--- as ONE batch SetClipGrades command. One command_manager entry, one
--- undo step, one grades_changed signal — at sync scale (1000+ clips on
--- a real timeline) N per-clip commands paid full command_manager
--- overhead each (state_hash, command:save, notify, signal) and turned
--- a one-shot sync into minutes of serialised work.
---
--- Returns a summary table: { applied_count, stale_marked,
--- unmatched_resolve_items, no_carrier_count }. The shape is
--- intentionally distinct from the pre-refactor `captured` table — the
--- inner batch command owns its own captured state.
function M.apply(response, sequence_id, db, synced_at)
    assert_response_shape(response)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "sync_grades.apply: sequence_id required (FR-013a scope)")
    assert(db, "sync_grades.apply: db required")
    assert(type(synced_at) == "number" and synced_at >= 0,
        "sync_grades.apply: synced_at unix timestamp required")

    local seq = Sequence.load(sequence_id)
    assert(seq, "sync_grades.apply: sequence not found: " .. sequence_id)
    assert(type(seq.project_id) == "string" and seq.project_id ~= "",
        "sync_grades.apply: sequence missing project_id "
        .. "(schema invariant)")
    local project_id = seq.project_id

    local valid_grades = filter_valid_grades(response.grades)
    local ops, unmatched, no_carrier_count, seen_clip_ids =
        plan_matched_ops(valid_grades, db, synced_at)
    local stale_ops = collect_stale_walk_ops(sequence_id, seen_clip_ids, db)

    -- Concatenate matched ops + stale-walk ops into one batch. Stale-walk
    -- ops never overlap matched ops (the walk skips clips in
    -- seen_clip_ids), so order is purely descriptive.
    local batch = {}
    for _, op in ipairs(ops)       do batch[#batch + 1] = op end
    for _, op in ipairs(stale_ops) do batch[#batch + 1] = op end

    if #batch > 0 then
        local result = command_manager.execute("SetClipGrades", {
            project_id  = project_id,
            sequence_id = sequence_id,
            clips       = batch,
        })
        assert(result and result.success, string.format(
            "sync_grades.apply: SetClipGrades batch failed: %s",
            result and result.error_message or "no result"))
    end

    -- Accounting (FR-011c report-not-skip discipline).
    local applied = #ops
    local stale_marked = #stale_ops
    log.event("SyncGradesFromResolve.apply: %d grade(s) applied, "
        .. "%d stale-marked, %d unmatched resolve_item_id(s)",
        applied, stale_marked, #unmatched)
    -- warn (default-visible), not event: each of these clips has a
    -- grade in Resolve but displays UNGRADED in JVE — user-visible
    -- damage that was silent in the 2026-06-10 incident (623 clips).
    if no_carrier_count > 0 then
        log.warn("SyncGradesFromResolve.apply: %d grade(s) have no "
            .. "displayable carrier (LUT bake failed Resolve-side?) — "
            .. "those clips display ungraded; re-run Sync Grades with "
            .. "Resolve left undisturbed during the bake",
            no_carrier_count)
    end

    return {
        applied_count           = applied,
        stale_marked            = stale_marked,
        unmatched_resolve_items = unmatched,
        no_carrier_count        = no_carrier_count,
    }
end

-- Forward declaration: defined after execute() (below), called from
-- within execute's inner closure. Local must be visible at the closure's
-- parse site.
local request_and_apply_grades

--- Full command path: pulls grades from helper, applies them, fires
--- on_complete. Non-blocking — on_complete carries success/error.
---
--- The outer command is non-undoable (SPEC.undoable=false); the single
--- SetClipGrades batch command dispatched from M.apply carries the undo
--- entry, so one Cmd-Z reverts the whole sync. `_command` accepted for
--- register_executor's executor signature; not used here.
function M.execute(args, db, _command)
    assert(type(args) == "table", "SyncGradesFromResolve: args required")
    assert(db, "SyncGradesFromResolve: db required (passed by "
        .. "register's executor closure; SQL isolation policy keeps "
        .. "the global DB lookup out of commands)")
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
                    bake_lut_dir)
            end)
    end)
end

-- Second half of the sync: read_grades → apply → notify. Split out so
-- execute() reads as the algorithm it is (discover → pull → apply).
-- `report` is discovery's result, folded into the notify payload so
-- callers see what got (un)linked alongside what got applied.
request_and_apply_grades = function(client, args, report, db,
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
    -- Apply a non-nil read_grades response and build its terminal
    -- (result, code, message) tuple for notify(). Returns the
    -- version_skew failure when the helper predates the warnings
    -- protocol; otherwise mutates the model via M.apply and returns the
    -- success payload. Internal-invariant asserts (e.g. a missing baked
    -- cube in new_grade_from_response_row) propagate as Lua errors to
    -- the caller's pcall — see the response handler below.
    --
    -- Helper anomaly channel (helper-protocol.md §read_grades
    -- `warnings`): bake/page anomalies that didn't fail the verb but
    -- leave user-visible damage (clips without a grade carrier, Resolve
    -- stuck on the Color page). Logged at warn so they're visible at
    -- default log level — stderr-only proved invisible in the
    -- 2026-06-10 incident. Missing field = version skew (helper predates
    -- this protocol); surface as structured error so the user can
    -- restart JVE to respawn the helper.
    local function build_terminal_result(response)
        if type(response.result.warnings) ~= "table" then
            return nil, "version_skew",
                "read_grades response has no warnings array — "
                .. "helper process predates this protocol; "
                .. "restart JVE to respawn the helper"
        end
        for _, w in ipairs(response.result.warnings) do
            log.warn("read_grades: %s", w)
        end
        local summary = M.apply(response.result, sequence_id, db,
            os.time())
        -- applied_count = response rows that landed on a JVE clip (via
        -- ledger). Excludes unmatched resolve_item_ids surfaced per
        -- FR-011c report-not-skip discipline.
        return {
            applied_count           = summary.applied_count,
            stale_marked            = summary.stale_marked,
            unmatched_resolve_items = summary.unmatched_resolve_items,
            no_carrier_count        = summary.no_carrier_count,
            -- What auto-discovery (FR-011c) just (un)linked — the
            -- counterpart of applied_count for identity. Callers and
            -- tests see matching outcomes per-sync instead of via a
            -- separate connect command's result.
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
        }, nil, nil
    end

    client:request("read_grades", helper_args,
        function(response, code, message)
            if response == nil then
                notify(args, nil, code, message)
                return
            end
            -- The apply phase can hit internal-invariant asserts (e.g. a
            -- baked cube missing from disk in new_grade_from_response_row).
            -- The C++ socket boundary SWALLOWS errors raised on this
            -- response callback — jve_invoke_lua_callback →
            -- jve_handle_lua_callback_error logs+pops+continues and never
            -- re-raises (see src/jve_lua_callback.h). So an un-caught
            -- assert here would never reach notify(): the *_completed
            -- signal would never fire and the FR-016 "Syncing…" indicator
            -- would hang until restart (rule 2.32 silent failure). Catch
            -- apply failures and route them through the ONE terminal path
            -- as a loud failure. No fallback values — the error is
            -- surfaced (error log + completion signal + on_complete), not
            -- masked as a fake result. apply_failed names the origin as a
            -- JVE-internal apply fault, distinct from resolve_api_error
            -- (rule 2.21 — don't conflate the failing layer).
            local ok, result, rcode, rmessage =
                pcall(build_terminal_result, response)
            if not ok then
                notify(args, nil, "apply_failed", tostring(result))
                return
            end
            notify(args, result, rcode, rmessage)
        end,
        { timeout_ms = BAKE_REQUEST_TIMEOUT_MS })
end

local SPEC = {
    -- The outer command is non-undoable: undo flows through the single
    -- SetClipGrades batch command M.apply dispatches. One Cmd-Z reverts
    -- the whole sync. Mirrors SyncEditsFromResolve.
    undoable      = false,
    -- Inner SetClipGrades touches clip_grade / resolve_bridge_link only
    -- (never the clips table) and drives UI via grades_changed; the
    -- clip-cache reload safety net in command_manager is correctly
    -- skipped — same rationale as SetClipGrades' own mutates_clips=false.
    mutates_clips = false,
    args = {
        sequence_id = { required = true,  kind = "string" },
        item_ids    = { required = false, kind = "table" },
        on_complete = { required = false, kind = "function" },
    },
}

M.register = OP.make_register(M.execute, SPEC)

return M
