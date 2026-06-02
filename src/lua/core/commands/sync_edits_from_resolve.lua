--- SyncEditsFromResolve — pull Resolve-side edit deltas back into JVE
--- (spec 023, T054, FR-024 / FR-025).
---
--- Two-pass design (see `specs/023-resolve-color-bridge/data-model.md`
--- §SyncEditsFromResolve — classification + dispatch contract):
---
---   * `M.classify_all` (this file, Pass 1 / T054a) — pure-data
---     classifier; walks the helper `read_timeline` response + the
---     ledger and buckets every clip into `to_apply`, `conflicts`,
---     `skipped`, or `unmatched`. No commands invoked.
---   * `M.apply` (Pass 2 / T054b, separate commit) — translates each
---     `to_apply` entry into existing JVE commands under one
---     `begin_undo_group`. No parallel clip-mutation path (1.9;
---     `feedback_no_lazy_shortcuts`).
---
--- V1 ships VIDEO ONLY (audio support deferred — see
--- `todo_t054_audio_support`). The classifier asserts on AUDIO clips.

local M = {}

local Clip            = require("models.clip")
local Track           = require("models.track")
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local edit_diff       = require("core.resolve_bridge.edit_diff")
local command_manager = require("core.command_manager")
local log             = require("core.logger").for_area("commands")

-- Closed-set reasons (module-local; tests assert literal strings, no
-- public exposure needed). Every emit asserts the reason it carries is
-- in the right set — catches typos and drift between spec and code
-- (2.21). Source: data-model.md §Closed-set reasons.
local CONFLICT_REASONS = {
    diverged_both_sides           = true,
    deleted_in_resolve            = true,
    fps_mismatch_unsupported      = true,
    subframe_unsupported          = true,
    unknown_delta_shape           = true,
    composite_undecomposable      = true,
    mutual_composite              = true,
    overwrite_absorb_inconsistent = true,
    slip_unsupported              = true,
    roll_unsupported              = true,
    multi_mapped_ambiguous        = true,
    missing_target_track_in_jve   = true,
}
local SKIP_REASONS = {
    neither_changed                = true,
    only_jve_changed               = true,
    no_modal_v1_unhandled_conflict = true,
    stale_user_choice              = true,
    phase0_failed                  = true,
    phaseB_failed                  = true,
}
local UNMATCHED_REASONS = {
    ledger_missing = true,
}

-- Required item fields the classifier asserts up-front (V1 video shape;
-- audio item shape lands with `todo_t054_audio_support`). track_id is
-- the JVE track id — see `contracts/helper-protocol.md` §read_timeline.
local REQUIRED_ITEM_NUMBER_FIELDS = {
    "source_in", "source_out", "record_start", "record_duration",
}

local function assert_response_shape(response)
    assert(type(response) == "table" and type(response.items) == "table",
        "sync_edits.classify_all: response.items array required")
    local seen = {}
    for i, row in ipairs(response.items) do
        assert(type(row.resolve_item_id) == "string"
                and row.resolve_item_id ~= "",
            string.format(
                "sync_edits.classify_all: item[%d] missing resolve_item_id",
                i))
        assert(seen[row.resolve_item_id] == nil, string.format(
            "sync_edits.classify_all: duplicate resolve_item_id=%s at "
            .. "item[%d] (every sync item must be unique)",
            row.resolve_item_id, i))
        seen[row.resolve_item_id] = true
        assert(type(row.track_id) == "string" and row.track_id ~= "",
            string.format(
                "sync_edits.classify_all: item[%d] missing track_id",
                i))
        for _, k in ipairs(REQUIRED_ITEM_NUMBER_FIELDS) do
            assert(type(row[k]) == "number", string.format(
                "sync_edits.classify_all: item[%d] missing %s (number)",
                i, k))
        end
        assert(type(row.enabled) == "boolean", string.format(
            "sync_edits.classify_all: item[%d] missing enabled (boolean)",
            i))
    end
end

-- Pull the JVE-current edit state + the per-clip context the classifier
-- needs (track / sequence / rate). Field-name mapping per
-- [[feedback_clip_lua_field_names]]: SQL `sequence_start_frame` etc.
-- become Lua `sequence_start`; the fingerprint vocabulary uses
-- `record_start` / `record_dur`, so we adapt here.
local function load_current_state(clip_id)
    local clip = Clip.load_optional(clip_id)
    if clip == nil then return nil end
    return {
        source_in           = clip.source_in,
        source_out          = clip.source_out,
        record_start        = clip.sequence_start,
        record_dur          = clip.duration,
        enabled             = clip.enabled,
        track_id            = clip.track_id,
        track_type          = clip.track_type,
        owner_sequence_id   = clip.owner_sequence_id,
        frame_rate          = clip.frame_rate,
        fps_mismatch_policy = clip.fps_mismatch_policy,
    }
end

-- Helper field-name map: helper-protocol `record_duration` →
-- fingerprint vocab `record_dur`.
local function live_state_from_response_row(row)
    return {
        source_in    = row.source_in,
        source_out   = row.source_out,
        record_start = row.record_start,
        record_dur   = row.record_duration,
        enabled      = row.enabled,
    }
end

-- Central emit point; validates closed-set membership and appends.
local function emit(bucket_name, entry, result)
    if bucket_name == "to_apply" then
        assert(entry.kind == "resolve_only", string.format(
            "sync_edits.emit: to_apply entry kind must be resolve_only "
            .. "(got %s)", tostring(entry.kind)))
    elseif bucket_name == "conflicts" then
        assert(CONFLICT_REASONS[entry.reason], string.format(
            "sync_edits.emit: conflicts.reason '%s' not in closed set",
            tostring(entry.reason)))
    elseif bucket_name == "skipped" then
        assert(SKIP_REASONS[entry.reason], string.format(
            "sync_edits.emit: skipped.reason '%s' not in closed set",
            tostring(entry.reason)))
    elseif bucket_name == "unmatched" then
        assert(UNMATCHED_REASONS[entry.reason], string.format(
            "sync_edits.emit: unmatched.reason '%s' not in closed set",
            tostring(entry.reason)))
    else
        error("sync_edits.emit: unknown bucket " .. tostring(bucket_name))
    end
    table.insert(result[bucket_name], entry)
end

-- Track-change branch: dispatch is `MoveClipToTrack` if the target
-- track exists in JVE; otherwise a `missing_target_track_in_jve`
-- conflict (Phase-0 dispatch would fail without a target). Early
-- return; the edit-diff path is skipped on track moves — Pass-2
-- dispatcher reloads `running` after MoveClipToTrack so Phase B picks
-- up any geometric residual on the new track.
local function classify_track_change(row, current, clip_id, result)
    local live = live_state_from_response_row(row)
    if Track.load(row.track_id) ~= nil then
        emit("to_apply", {
            clip_id             = clip_id,
            resolve_item_id     = row.resolve_item_id,
            kind                = "resolve_only",
            live                = live,
            current             = current,
            stored_fp           = nil,
            track_id            = current.track_id,
            track_type          = current.track_type,
            requires_track_move = true,
            target_track_id     = row.track_id,
        }, result)
    else
        emit("conflicts", {
            clip_id         = clip_id,
            resolve_item_id = row.resolve_item_id,
            reason          = "missing_target_track_in_jve",
            live            = live,
            current         = current,
            track_id        = current.track_id,
            track_type      = current.track_type,
            live_track_id   = row.track_id,
        }, result)
    end
end

-- Edit-diff branch: fingerprint comparison, bootstrap path, kind →
-- bucket+reason mapping.
local function classify_edit_diff(row, current, clip_id, db,
                                   take_resolve_set, result)
    local link = identity_ledger.load(clip_id, db)
    assert(link ~= nil, string.format(
        "sync_edits.classify_row: ledger row vanished between "
        .. "lookup_clip_id and load for resolve_item_id=%s",
        row.resolve_item_id))

    local stored_fp
    local bootstrapped = false
    if take_resolve_set and take_resolve_set[clip_id] then
        -- Take-Resolve override: synthesize stored_fp from current so
        -- live ≠ stored == current → kind=resolve_only → joins the
        -- natural to_apply flow.
        stored_fp = edit_diff.fingerprint(current)
    elseif link.edit_fingerprint == nil then
        stored_fp    = edit_diff.fingerprint(current)
        bootstrapped = true
    else
        stored_fp = link.edit_fingerprint
    end

    local live       = live_state_from_response_row(row)
    local classified = edit_diff.classify(live, stored_fp, current)
    local entry = {
        clip_id         = clip_id,
        resolve_item_id = row.resolve_item_id,
        live            = live,
        current         = current,
        stored_fp       = stored_fp,
        track_id        = current.track_id,
        track_type      = current.track_type,
    }
    if bootstrapped then entry.bootstrapped = true end

    if classified.kind == "resolve_only" then
        entry.kind = "resolve_only"
        emit("to_apply", entry, result)
    elseif classified.kind == "both" then
        entry.kind   = "both"
        entry.reason = "diverged_both_sides"
        emit("conflicts", entry, result)
    elseif classified.kind == "neither" then
        entry.reason = "neither_changed"
        emit("skipped", entry, result)
    elseif classified.kind == "jve_only" then
        entry.reason = "only_jve_changed"
        emit("skipped", entry, result)
    else
        error("sync_edits.classify_row: edit_diff.classify returned "
            .. "unknown kind " .. tostring(classified.kind))
    end
end

local function classify_row(row, sequence_id, db, take_resolve_set, result)
    local clip_id = identity_ledger.lookup_clip_id(row.resolve_item_id, db)
    if clip_id == nil then
        emit("unmatched", {
            resolve_item_id = row.resolve_item_id,
            reason          = "ledger_missing",
        }, result)
        return
    end

    local current = load_current_state(clip_id)
    -- FK invariant: `resolve_bridge_link.jve_clip_uuid REFERENCES
    -- clips(id) ON DELETE CASCADE` ⇒ a ledger row whose clip is gone
    -- is structurally impossible. Pinned by
    -- `tests/test_resolve_bridge_link_schema.lua`.
    assert(current ~= nil, string.format(
        "sync_edits.classify_row: ledger row points at missing clip %s "
        .. "(FK CASCADE violated) — DB corruption", clip_id))
    assert(current.owner_sequence_id == sequence_id, string.format(
        "sync_edits.classify_row: clip %s belongs to sequence %s, not %s "
        .. "(cross-sequence ledger contamination)",
        clip_id, tostring(current.owner_sequence_id), tostring(sequence_id)))
    -- V1 video-only. Audio support lands separately (see
    -- todo_t054_audio_support).
    assert(current.track_type == "VIDEO", string.format(
        "sync_edits.classify_row: V1 sync supports VIDEO tracks only; "
        .. "clip %s on track_type=%s", clip_id, tostring(current.track_type)))

    if row.track_id ~= current.track_id then
        classify_track_change(row, current, clip_id, result)
        return
    end
    classify_edit_diff(row, current, clip_id, db, take_resolve_set, result)
end

-- Surface any ledger row for the sequence whose resolve_item_id was
-- absent from the response — Resolve no longer has the clip. Bucketed
-- as a conflict so the user picks Keep-JVE vs Delete-locally in Pass 2;
-- V1-MVP no-modal path drops these to skipped(no_modal_v1_unhandled_conflict).
local function walk_ledger_for_deleted(sequence_id, seen_resolve_ids, db,
                                        result)
    local stmt = assert(db:prepare([[
        SELECT rbl.jve_clip_uuid, rbl.resolve_item_id
        FROM resolve_bridge_link rbl
        JOIN clips c ON c.id = rbl.jve_clip_uuid
        WHERE c.owner_sequence_id = ?
    ]]), "sync_edits.walk_ledger_for_deleted: prepare failed")
    stmt:bind_value(1, sequence_id)
    if not stmt:exec() then
        stmt:finalize()
        error("sync_edits.walk_ledger_for_deleted: exec failed for "
            .. "sequence " .. tostring(sequence_id))
    end
    while stmt:next() do
        local clip_id  = stmt:value(0)
        local resolve_item_id = stmt:value(1)
        if seen_resolve_ids[resolve_item_id] == nil then
            emit("conflicts", {
                clip_id         = clip_id,
                resolve_item_id = resolve_item_id,
                reason          = "deleted_in_resolve",
            }, result)
        end
    end
    stmt:finalize()
end

--- Classify a `read_timeline` response into action buckets.
---
--- @param response         table  {items = [...]} per helper-protocol.md
--- @param sequence_id      string JVE sequence the response describes
--- @param db               table  open SQLite connection
--- @param take_resolve_set table? {[clip_id] = true}; clips whose stored
---                                fingerprint should be synthesized from
---                                current (Take-Resolve user choice).
---                                Pass-1 callers leave nil.
--- @return table {to_apply, conflicts, skipped, unmatched}
---
--- Trust assumptions (data-model.md §SyncEditsFromResolve → Scope):
---   - One Resolve timeline per response (helper-protocol guarantee).
---   - Schema V12+ (resolve_bridge_link table + resolve_item_id index).
---   - V1 VIDEO only; AUDIO clips assert.
--- Iteration order through buckets is response order, NOT contractual;
--- callers key by clip_id (or resolve_item_id for unmatched).
function M.classify_all(response, sequence_id, db, take_resolve_set)
    assert_response_shape(response)
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "sync_edits.classify_all: sequence_id required")
    assert(db, "sync_edits.classify_all: db required")
    if take_resolve_set ~= nil then
        assert(type(take_resolve_set) == "table",
            "sync_edits.classify_all: take_resolve_set must be table or nil")
    end

    local result = {
        to_apply  = {},
        conflicts = {},
        skipped   = {},
        unmatched = {},
    }
    local seen_resolve_ids = {}
    for _, row in ipairs(response.items) do
        seen_resolve_ids[row.resolve_item_id] = true
        classify_row(row, sequence_id, db, take_resolve_set, result)
    end
    walk_ledger_for_deleted(sequence_id, seen_resolve_ids, db, result)
    return result
end

-- Closed-set verbs the dispatcher may invoke. Mirrors data-model.md
-- §SyncEditsFromResolve → Dispatch verbs. Adding a verb requires
-- updating this constant AND the spec; the dispatcher asserts every
-- command_manager.execute name is in this set (2.21).
local DISPATCH_VERBS = {
    MoveClipToTrack    = true,
    ToggleClipEnabled  = true,
    RippleTrimEdge     = true,
    OverwriteTrimEdge  = true,
    Nudge              = true,
    DeleteClip         = true,
    RippleDelete       = true,
}

-- Compute the post-success fingerprint that would persist for an
-- entry whose live state has been fully applied. Pulled from the entry's
-- `live` (live state from Resolve) plus the original `current.enabled`
-- iff Phase A was not executed — but for B1, only Phase 0 runs and the
-- live geometric fields already equal `current`'s for any clip that
-- entered Phase 0 (track-only delta — fingerprint excludes track_id).
-- So the fingerprint to persist == fingerprint(live), with `enabled`
-- pinned to live.enabled.
local function fingerprint_for_persist(entry)
    return edit_diff.fingerprint(entry.live)
end

-- Bootstrap fingerprint persistence. Walks `skipped[]` and `to_apply[]`
-- for entries the classifier marked `bootstrapped = true` and writes
-- `link.edit_fingerprint = stored_fp`. Outside the undo group because
-- it is metadata catch-up, not a user-visible edit (data-model.md
-- §apply step 3).
local function persist_bootstrap_fingerprints(classified, db, persisted_list)
    local function persist_one(entry)
        if not entry.bootstrapped then return end
        assert(entry.stored_fp ~= nil and entry.stored_fp ~= "",
            "sync_edits.apply: bootstrap entry missing stored_fp "
            .. "(clip_id=" .. tostring(entry.clip_id) .. ")")
        identity_ledger.upsert(entry.clip_id, {
            resolve_item_id  = entry.resolve_item_id,
            edit_fingerprint = entry.stored_fp,
        }, db)
        table.insert(persisted_list, {
            clip_id          = entry.clip_id,
            resolve_item_id  = entry.resolve_item_id,
            edit_fingerprint = entry.stored_fp,
            origin           = "bootstrap",
        })
    end
    for _, e in ipairs(classified.skipped)  do persist_one(e) end
    for _, e in ipairs(classified.to_apply) do persist_one(e) end
end

-- V1 no-modal conflict surface (data-model.md §apply step 4 — V1 MVP
-- path ignores user_choices and surfaces conflicts as skipped). Pure
-- transform; no DB writes.
local function surface_conflicts_as_skipped(classified, result)
    -- Carry the classifier's fields through verbatim — same shape the
    -- modal would receive in V2 — so callers/log readers can inspect
    -- why the conflict was bucketed. Only `reason` is rewritten.
    for _, c in ipairs(classified.conflicts) do
        table.insert(result.skipped, {
            clip_id         = c.clip_id,
            resolve_item_id = c.resolve_item_id,
            reason          = "no_modal_v1_unhandled_conflict",
            kind            = c.kind,
            live            = c.live,
            current         = c.current,
            stored_fp       = c.stored_fp,
            track_id        = c.track_id,
            track_type      = c.track_type,
            live_track_id   = c.live_track_id,
        })
    end
    for _, s in ipairs(classified.skipped) do
        table.insert(result.skipped, s)
    end
end

-- Dispatch one verb with closed-set validation. Returns (ok, error_message).
-- Asserts the verb is in DISPATCH_VERBS before invoking command_manager —
-- catches drift between this dispatcher and the spec's verb list (2.21).
local function dispatch_verb(verb, params)
    assert(DISPATCH_VERBS[verb], string.format(
        "sync_edits.dispatch_verb: verb %q not in DISPATCH_VERBS "
        .. "(closed set drift vs data-model.md)", tostring(verb)))
    local exec_result = command_manager.execute(verb, params)
    assert(type(exec_result) == "table"
            and type(exec_result.success) == "boolean",
        string.format(
            "sync_edits.dispatch_verb: command_manager.execute(%s) "
            .. "returned non-conforming result", verb))
    if exec_result.success then return true, nil end
    return false, exec_result.error_message or ""
end

-- Per-clip dispatch state, built up across phases. Each clip starts
-- with `{ attempted_verbs = {}, all_succeeded = true, failed = nil }`
-- and is mutated by run_phase_*; result.applied / result.failed get
-- assembled from this state once dispatch finishes.
local function new_per_clip_state(entry)
    return {
        entry          = entry,
        attempted_verbs = {},
        all_succeeded  = true,
        phase0_status  = "not_needed",
        phaseA_status  = "not_needed",
    }
end

local function init_per_clip(to_apply_entries)
    local per_clip = {}
    for _, entry in ipairs(to_apply_entries) do
        per_clip[entry.clip_id] = new_per_clip_state(entry)
    end
    return per_clip
end

local function record_failure(state, verb, args, err, result)
    state.all_succeeded = false
    table.insert(result.failed, {
        clip_id         = state.entry.clip_id,
        resolve_item_id = state.entry.resolve_item_id,
        attempted_verb  = verb,
        args            = args,
        error           = err,
    })
end

-- Phase 0: MoveClipToTrack for every to_apply entry with
-- requires_track_move = true. Phase 0 failure cascade-skips A/B/C
-- (data-model.md §apply step 8 failure cascade) — caller observes
-- `state.phase0_status == "ran_failed"` and refuses subsequent phases
-- for that clip.
local function run_phase_0(per_clip, project_id, sequence_id, result)
    for _, state in pairs(per_clip) do
        local entry = state.entry
        if not entry.requires_track_move then
            state.phase0_status = "not_needed"
        else
            assert(type(entry.target_track_id) == "string"
                    and entry.target_track_id ~= "",
                "sync_edits.run_phase_0: requires_track_move entry "
                .. "missing target_track_id (clip_id="
                .. tostring(entry.clip_id) .. ")")
            local ok, err = dispatch_verb("MoveClipToTrack", {
                clip_id         = entry.clip_id,
                target_track_id = entry.target_track_id,
                project_id      = project_id,
                sequence_id     = sequence_id,
            })
            if ok then
                state.phase0_status = "ran_ok"
                table.insert(state.attempted_verbs, "MoveClipToTrack")
            else
                state.phase0_status = "ran_failed"
                record_failure(state, "MoveClipToTrack",
                    { target_track_id = entry.target_track_id },
                    err, result)
                table.insert(result.skipped, {
                    clip_id         = entry.clip_id,
                    resolve_item_id = entry.resolve_item_id,
                    reason          = "phase0_failed",
                })
                log.warn("sync_edits: Phase 0 MoveClipToTrack failed "
                    .. "for clip %s: %s", tostring(entry.clip_id),
                    tostring(err))
            end
        end
    end
end

-- Phase A: ToggleClipEnabled for every to_apply entry where
-- live.enabled ≠ current.enabled. Skipped for any clip whose Phase 0
-- failed (cascade per data-model.md §apply failure cascade — Phase 0
-- failure cascade-skips A/B/C). Phase A failure is INDEPENDENT — it
-- does not cascade-skip later phases because `enabled` is
-- geometrically inert. Dispatched via explicit `clip_toggles` form
-- (idempotent: sets exact enabled_after; not a blind flip).
local function run_phase_a(per_clip, project_id, sequence_id, result)
    for _, state in pairs(per_clip) do
        local entry = state.entry
        local delta = entry.live.enabled ~= entry.current.enabled
        if not delta then
            state.phaseA_status = "not_needed"
        elseif state.phase0_status == "ran_failed" then
            state.phaseA_status = "skipped_phase0_failed"
        else
            local ok, err = dispatch_verb("ToggleClipEnabled", {
                project_id  = project_id,
                sequence_id = sequence_id,
                clip_toggles = { {
                    clip_id        = entry.clip_id,
                    enabled_before = entry.current.enabled,
                    enabled_after  = entry.live.enabled,
                } },
            })
            if ok then
                state.phaseA_status = "ran_ok"
                table.insert(state.attempted_verbs, "ToggleClipEnabled")
            else
                state.phaseA_status = "ran_failed"
                record_failure(state, "ToggleClipEnabled",
                    { enabled_after = entry.live.enabled },
                    err, result)
                log.warn("sync_edits: Phase A ToggleClipEnabled failed "
                    .. "for clip %s: %s", tostring(entry.clip_id),
                    tostring(err))
            end
        end
    end
end

-- Assemble result.applied + fingerprints_persisted from per_clip.
-- A clip lands in applied[] iff it dispatched ≥ 1 verb successfully.
-- Its fingerprint persists iff ALL attempted phases succeeded
-- (data-model.md §apply step 14 — partial-success clips retain prior
-- fingerprint so the next sync retries).
local function finalize_per_clip(per_clip, to_apply_entries, db, result)
    -- Walk to_apply_entries (not pairs(per_clip)) to keep applied[] /
    -- fingerprints_persisted[] ordering deterministic — Lua pairs is
    -- unordered and tests rely on response-order semantics.
    for _, entry in ipairs(to_apply_entries) do
        local state = per_clip[entry.clip_id]
        if #state.attempted_verbs > 0 then
            table.insert(result.applied, {
                clip_id         = entry.clip_id,
                resolve_item_id = entry.resolve_item_id,
                attempted_verbs = state.attempted_verbs,
            })
        end
        if state.all_succeeded
            and (state.phase0_status == "ran_ok"
                 or state.phaseA_status == "ran_ok") then
            local fp = fingerprint_for_persist(entry)
            identity_ledger.upsert(entry.clip_id, {
                resolve_item_id  = entry.resolve_item_id,
                edit_fingerprint = fp,
            }, db)
            table.insert(result.fingerprints_persisted, {
                clip_id          = entry.clip_id,
                resolve_item_id  = entry.resolve_item_id,
                edit_fingerprint = fp,
                origin           = "phase_success",
            })
        end
    end
end

-- Stage guard: reject to_apply entries that need phases not yet
-- implemented in this commit. T054b-2 wires Phase 0 + Phase A; any
-- residual on source_in / source_out / record_start / record_dur
-- needs Phase B/C/D and aborts apply() with a clear staging message.
-- Not a stub (2.17) — the dispatcher truthfully refuses work it
-- cannot perform. T054b-3/4 relax and finally remove this guard.
local function assert_no_unimplemented_phases(to_apply_entries)
    for _, entry in ipairs(to_apply_entries) do
        local live = entry.live
        local cur  = entry.current
        local geom_delta =
            live.source_in    ~= cur.source_in
            or live.source_out  ~= cur.source_out
            or live.record_start ~= cur.record_start
            or live.record_dur   ~= cur.record_dur
        if geom_delta then
            error(string.format(
                "sync_edits.apply: to_apply entry for clip %s has "
                .. "geometric residual (Δ source_in/out or record_*); "
                .. "Phases B/C/D land in subsequent T054b commits. "
                .. "T054b-2 dispatches Phase 0 (track move) + Phase A "
                .. "(enabled toggle) only.",
                tostring(entry.clip_id)))
        end
    end
end

--- Pull Resolve-side edit deltas back into JVE (data-model.md
--- §SyncEditsFromResolve, FR-024 / FR-025).
---
--- @param response     table  helper read_timeline payload
--- @param sequence_id  string JVE sequence the response describes
--- @param project_id   string JVE project (required by dispatched verbs)
--- @param db           table  open SQLite connection
--- @param user_choices table? V2; V1 MVP must pass nil
--- @return table {applied, failed, skipped, fingerprints_persisted}
---
--- V1 MVP scope (T054b-1 + T054b-2): Phase 0 (`MoveClipToTrack`) +
--- Phase A (`ToggleClipEnabled`) + bootstrap fingerprint persist + V1
--- no-modal conflict surface. Entries with geometric residual on
--- source_in/source_out/record_start/record_dur abort with a staging
--- message; Phases B/C/D land in T054b-3/4.
function M.apply(response, sequence_id, project_id, db, user_choices)
    assert(type(project_id) == "string" and project_id ~= "",
        "sync_edits.apply: project_id required")
    assert(user_choices == nil,
        "sync_edits.apply: user_choices is V2 only; V1 MVP must pass "
        .. "nil (conflicts surface as skipped with reason "
        .. "no_modal_v1_unhandled_conflict)")

    local classified = M.classify_all(response, sequence_id, db, nil)

    local result = {
        applied                 = {},
        failed                  = {},
        skipped                 = {},
        fingerprints_persisted  = {},
    }

    persist_bootstrap_fingerprints(classified, db,
        result.fingerprints_persisted)
    surface_conflicts_as_skipped(classified, result)

    if #classified.to_apply == 0 then return result end

    assert_no_unimplemented_phases(classified.to_apply)

    local per_clip = init_per_clip(classified.to_apply)
    command_manager.begin_undo_group("Sync Edits from Resolve")
    run_phase_0(per_clip, project_id, sequence_id, result)
    run_phase_a(per_clip, project_id, sequence_id, result)
    command_manager.end_undo_group()

    finalize_per_clip(per_clip, classified.to_apply, db, result)
    return result
end

return M
