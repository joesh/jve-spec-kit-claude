--- SyncEditsFromResolve — pull Resolve-side edit deltas back into JVE
--- (spec 023 FR-024 / FR-025).
---
--- Two-pass design (see `specs/023-resolve-color-bridge/data-model.md`
--- §SyncEditsFromResolve — classification + dispatch contract):
---
---   * `M.classify_all` (Pass 1) — pure-data classifier; walks the
---     helper `read_timeline` response + the ledger and buckets every
---     clip into `to_apply`, `conflicts`, `skipped`, or `unmatched`.
---     No commands invoked.
---   * `M.apply` (Pass 2) — translates each `to_apply` entry into
---     existing JVE commands under one `begin_undo_group`. No
---     parallel clip-mutation path (1.9; `feedback_no_lazy_shortcuts`).
---
--- V1 ships VIDEO ONLY (audio support deferred — see
--- `todo_t054_audio_support`). The classifier asserts on AUDIO clips.

local wire           = require("core.resolve_bridge.wire_decode")

local M = {}

local Clip              = require("models.clip")
local Track             = require("models.track")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local discovery         = require("core.resolve_bridge.discovery")
local edit_diff         = require("core.resolve_bridge.edit_diff")
local supervisor        = require("core.resolve_bridge.helper_supervisor")
local command_manager   = require("core.command_manager")
local bridge_command    = require("core.commands.bridge_command")
local log               = require("core.logger").for_area("commands")

local OP = bridge_command.declare(
    "SyncEditsFromResolve", "sync_edits_from_resolve_completed")
local notify = OP.notify

-- Closed-set reasons (module-local; tests assert literal strings, no
-- public exposure needed). Every emit asserts the reason it carries is
-- in the right set — catches typos and drift between spec and code
-- (2.21). Source: data-model.md §Closed-set reasons.
local CONFLICT_REASONS = {
    diverged_both_sides           = true,
    deleted_in_resolve            = true,
    fps_mismatch_unsupported      = true,
    subframe_unsupported          = true,
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
    unknown_delta_shape            = true,
}
local UNMATCHED_REASONS = {
    ledger_missing = true,
}

-- Required item fields the classifier asserts up-front (V1 video shape;
-- audio item shape lands with `todo_t054_audio_support`). track_id at
-- the classifier layer is the JVE track id — produced by the wire→
-- classifier translation (`M.translate_wire_response`) which maps
-- helper-protocol's `(track_type, track_index)` onto JVE track UUIDs.
local REQUIRED_ITEM_NUMBER_FIELDS = {
    "source_in", "source_out", "record_start", "record_duration",
}

-- Wire-layer track-type set (helper-protocol.md §read_timeline). JVE's
-- own `tracks.track_type` column is uppercase; the helper returns
-- Resolve's lowercase convention. `translate_wire_response` upcases on
-- the way in.

-- Sentinel produced when a Resolve-side track has no JVE equivalent
-- (e.g. user added a track in Resolve since send). The classifier's
-- existing `classify_track_change` branch calls Track.load(row.track_id)
-- and emits `missing_target_track_in_jve` when nil — so any string
-- guaranteed-not-to-collide with a real JVE track UUID flows through
-- that path. Format encodes the original wire info for debugging.
local function missing_track_sentinel(track_type, track_index)
    return string.format("resolve-missing-track:%s:%d",
        track_type, track_index)
end

-- Validate wire-protocol required fields for a media item before it enters
-- the classifier. Returns nil on valid, or an error string on invalid.
-- Belongs here (wire boundary) so classify_all can assert internal
-- invariants without crashing on malformed external data.
local function validate_media_wire_item(w, i)
    if type(w.resolve_item_id) ~= "string" or w.resolve_item_id == "" then
        return string.format(
            "sync_edits.translate_wire_response: item[%d] "
            .. "missing resolve_item_id", i)
    end
    if wire.WIRE_TO_JVE_TRACK_TYPE[w.track_type] == nil then
        return string.format(
            "sync_edits.translate_wire_response: item[%d] "
            .. "track_type %q not in closed set {video, audio}",
            i, tostring(w.track_type))
    end
    if type(w.track_index) ~= "number"
            or w.track_index < 1
            or w.track_index ~= math.floor(w.track_index) then
        return string.format(
            "sync_edits.translate_wire_response: item[%d] "
            .. "track_index must be 1-based integer, got %s",
            i, tostring(w.track_index))
    end
    for _, k in ipairs(REQUIRED_ITEM_NUMBER_FIELDS) do
        if type(w[k]) ~= "number" then
            return string.format(
                "sync_edits.translate_wire_response: item[%d] "
                .. "missing %s (number)", i, k)
        end
    end
    if type(w.enabled) ~= "boolean" then
        return string.format(
            "sync_edits.translate_wire_response: item[%d] "
            .. "enabled must be boolean, got %s",
            i, tostring(w.enabled))
    end
    return nil
end

--- Translate a helper `read_timeline` wire response into the shape
--- `classify_all` consumes. The helper returns positional track
--- identity (`track_type`, `track_index`) because Resolve preserves DRT
--- track order through import (helper-protocol.md §read_timeline). JVE
--- resolves the pair to a JVE `track_id` via `Track.find_at`; items
--- whose Resolve track has no JVE counterpart get a sentinel string
--- that flows through the classifier's existing
--- `missing_target_track_in_jve` path.
---
--- @param wire_response table  `{items: [{resolve_item_id, track_type,
---                              track_index, record_start,
---                              record_duration, source_in, source_out,
---                              enabled}]}`
--- @param sequence_id   string JVE sequence the response describes
--- @return table        `{items: [{resolve_item_id, track_id, ...}]}`
---                      with all non-track fields carried verbatim.
function M.translate_wire_response(wire_response, sequence_id)
    assert(type(wire_response) == "table"
            and type(wire_response.items) == "table",
        "sync_edits.translate_wire_response: wire_response.items "
        .. "array required")
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "sync_edits.translate_wire_response: sequence_id required")

    local out_items = {}
    local non_media_skipped = 0
    for i, w in ipairs(wire_response.items) do
        -- kind is required at the wire boundary (helper-protocol.md
        -- §read_timeline). Non-media items (generators, transitions,
        -- adjustment clips, some Fusion comps) carry no source range
        -- and cannot participate in edit-fingerprint diffing — filter
        -- them out here at the translate seam so classify_all stays
        -- strict on source_in/source_out presence. Unknown kinds
        -- (helper newer than JVE) get a warn + skip — never a crash.
        local kind_valid, kind_err = wire.validate_item_kind(w.kind,
            string.format("sync_edits.translate_wire_response: item[%d]", i))
        if not kind_valid then
            log.warn(kind_err)
        elseif w.kind == "non_media" then
            non_media_skipped = non_media_skipped + 1
        else
            local field_err = validate_media_wire_item(w, i)
            if field_err ~= nil then
                log.warn(field_err)
            else
                local jve_track_type = wire.WIRE_TO_JVE_TRACK_TYPE[w.track_type]
                local jve_track_id   = Track.find_at(sequence_id,
                    jve_track_type, w.track_index)
                if jve_track_id == nil then
                    jve_track_id = missing_track_sentinel(w.track_type,
                        w.track_index)
                end
                out_items[#out_items + 1] = {
                    resolve_item_id = w.resolve_item_id,
                    track_id        = jve_track_id,
                    record_start    = w.record_start,
                    record_duration = w.record_duration,
                    source_in       = w.source_in,
                    source_out      = w.source_out,
                    enabled         = w.enabled,
                }
            end
        end
    end
    if non_media_skipped > 0 then
        log.event("SyncEdits: skipped %d non-media items (generators/transitions/etc.)",
            non_media_skipped)
    end
    local audio_skipped = wire_response.audio_items_skipped
    if audio_skipped == nil then
        log.warn("SyncEdits: helper did not send audio_items_skipped "
            .. "(helper-protocol §read_timeline — version skew?)")
    elseif type(audio_skipped) ~= "number" then
        log.warn("SyncEdits: audio_items_skipped is not a number: "
            .. tostring(audio_skipped))
    elseif audio_skipped > 0 then
        log.event("SyncEdits: skipped %d audio items (audio deferred — see todo_t054)",
            audio_skipped)
    end
    return {
        items = out_items,
        timeline_integer_rate = wire_response.timeline_integer_rate,
    }
end

-- Internal invariant guard — all wire field validation belongs in
-- translate_wire_response (validate_media_wire_item). These asserts fire
-- only if our own code produced malformed output, not on wire data.
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
    -- Rule 2.5: Use centralized iterator for sequence links (review item #1).
    local links = identity_ledger.iter_links_for_sequence(sequence_id, db)
    for _, link in ipairs(links) do
        local clip_id  = link.clip_id
        local resolve_item_id = link.resolve_item_id
        if seen_resolve_ids[resolve_item_id] == nil then
            emit("conflicts", {
                clip_id         = clip_id,
                resolve_item_id = resolve_item_id,
                reason          = "deleted_in_resolve",
            }, result)
        end
    end
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
---   - Schema V13+ (resolve_bridge_link table + resolve_item_id index).
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

-- Post-success fingerprint: the Resolve-side `live` state we just
-- caught JVE up to. Fingerprint vocabulary excludes track_id, so a
-- track-only Phase-0 success persists `fingerprint(live)` correctly
-- (live geometric fields already equal current's).
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
    assert(type(exec_result.error_message) == "string"
            and exec_result.error_message ~= "",
        string.format(
            "sync_edits.dispatch_verb: %s failed with empty error_message "
            .. "(command_manager contract violation)", verb))
    return false, exec_result.error_message
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
        phaseB_status  = "not_needed",
        phaseC_status  = "not_needed",
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
-- for that clip. Iterates `to_apply_entries` (response order) rather
-- than `pairs(per_clip)` to keep result.failed / result.skipped
-- deterministic.
local function run_phase_0(to_apply_entries, per_clip, project_id,
                            sequence_id, result)
    for _, entry in ipairs(to_apply_entries) do
        local state = per_clip[entry.clip_id]
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
-- (idempotent: sets exact enabled_after; not a blind flip). Iterates
-- `to_apply_entries` for deterministic dispatch order (same reason as
-- run_phase_0).
local function run_phase_a(to_apply_entries, per_clip, project_id,
                            sequence_id, result)
    for _, entry in ipairs(to_apply_entries) do
        local state = per_clip[entry.clip_id]
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

-- Phase B: pure-trim convergence via OverwriteTrimEdge per nonzero
-- edge delta. Algebra (forward clip):
--   LEFT  edge by L: Δsource_in=+L, Δsource_out=0, Δrecord_start=+L,
--                    Δrecord_dur=-L
--   RIGHT edge by R: Δsource_in=0,  Δsource_out=+R, Δrecord_start=0,
--                    Δrecord_dur=+R
-- So L = Δsource_in, R = Δsource_out. The trim-decomposability gate
-- (assert_no_unimplemented_phases) has already rejected residuals
-- where Δrecord_start ≠ L or Δrecord_dur ≠ R - L.
--
-- V1 dispatches OverwriteTrimEdge (not RippleTrimEdge): Resolve gives
-- us per-clip absolute live positions, so single-clip overwrite
-- converges each entry to its live target independently. RippleTrim
-- would shift OTHER to_apply clips off their targets — wrong here.
-- The data-model's "blanket reload after each RippleTrim" caveat
-- therefore does not apply in V1 (no RippleTrim dispatched).
--
-- Cascade: phase0_failed → skip B (geom ops on a wrong-track clip are
-- meaningless). phaseB_failed → push entry to result.failed and
-- cascade-skip C (data-model.md §apply failure cascade). Within a
-- clip: left dispatched before right; if left fails, right is skipped
-- (clip didn't converge — no point further mutating it). Reloads
-- current state per clip so Phase 0's track-move doesn't stale-shadow
-- the source/record snapshot taken at classify time.
local function run_phase_b(to_apply_entries, per_clip, project_id,
                            sequence_id, result)
    for _, entry in ipairs(to_apply_entries) do
        local state = per_clip[entry.clip_id]
        if state.phase0_status == "ran_failed" then
            state.phaseB_status = "skipped_phase0_failed"
        else
            local cur = load_current_state(entry.clip_id)
            assert(cur ~= nil, string.format(
                "sync_edits.run_phase_b: clip %s vanished mid-dispatch "
                .. "(FK CASCADE or concurrent delete)",
                tostring(entry.clip_id)))
            local L = entry.live.source_in  - cur.source_in
            local R = entry.live.source_out - cur.source_out
            if L == 0 and R == 0 then
                state.phaseB_status = "not_needed"
            else
                local left_ok = true
                if L ~= 0 then
                    local ok, err = dispatch_verb("OverwriteTrimEdge", {
                        clip_id      = entry.clip_id,
                        edge         = "left",
                        delta_frames = L,
                        sequence_id  = sequence_id,
                        project_id   = project_id,
                    })
                    if ok then
                        table.insert(state.attempted_verbs, "OverwriteTrimEdge")
                    else
                        left_ok = false
                        state.phaseB_status = "ran_failed"
                        record_failure(state, "OverwriteTrimEdge",
                            { edge = "left", delta_frames = L }, err, result)
                        log.warn("sync_edits: Phase B left-trim failed "
                            .. "for clip %s: %s", tostring(entry.clip_id),
                            tostring(err))
                    end
                end
                if left_ok and R ~= 0 then
                    local ok, err = dispatch_verb("OverwriteTrimEdge", {
                        clip_id      = entry.clip_id,
                        edge         = "right",
                        delta_frames = R,
                        sequence_id  = sequence_id,
                        project_id   = project_id,
                    })
                    if ok then
                        table.insert(state.attempted_verbs, "OverwriteTrimEdge")
                    else
                        state.phaseB_status = "ran_failed"
                        record_failure(state, "OverwriteTrimEdge",
                            { edge = "right", delta_frames = R }, err, result)
                        log.warn("sync_edits: Phase B right-trim failed "
                            .. "for clip %s: %s", tostring(entry.clip_id),
                            tostring(err))
                    end
                end
                if state.phaseB_status == "not_needed" then
                    state.phaseB_status = "ran_ok"
                end
            end
        end
    end
end

-- Phase C: Nudge residual record_start shift left over after Phase B.
-- Decomposition: a clip's residual decomposes (Phase B + Phase C) as
-- L = Δsource_in, R = Δsource_out, M = Δrecord_start − L; Phase B
-- handles L/R, Phase C nudges by M. By the partition gate
-- (see surface_shape_failures), every runnable entry already
-- satisfies Δrecord_dur == R − L; Phase B has applied L/R, so the
-- reloaded Δrecord_start is exactly the leftover M. Cascade:
-- phase0_failed → skipped_phase0_failed; phaseB_failed →
-- skipped_phaseB_failed.
local function run_phase_c(to_apply_entries, per_clip, project_id,
                            sequence_id, result)
    for _, entry in ipairs(to_apply_entries) do
        local state = per_clip[entry.clip_id]
        if state.phase0_status == "ran_failed" then
            state.phaseC_status = "skipped_phase0_failed"
        elseif state.phaseB_status == "ran_failed" then
            state.phaseC_status = "skipped_phaseB_failed"
        else
            local cur = load_current_state(entry.clip_id)
            assert(cur ~= nil, string.format(
                "sync_edits.run_phase_c: clip %s vanished mid-dispatch "
                .. "(FK CASCADE or concurrent delete)",
                tostring(entry.clip_id)))
            local nudge_amount = entry.live.record_start - cur.record_start
            if nudge_amount == 0 then
                state.phaseC_status = "not_needed"
            else
                local ok, err = dispatch_verb("Nudge", {
                    selected_clip_ids = { entry.clip_id },
                    nudge_amount      = nudge_amount,
                    sequence_id       = sequence_id,
                    project_id        = project_id,
                })
                if ok then
                    state.phaseC_status = "ran_ok"
                    table.insert(state.attempted_verbs, "Nudge")
                else
                    state.phaseC_status = "ran_failed"
                    record_failure(state, "Nudge",
                        { nudge_amount = nudge_amount }, err, result)
                    log.warn("sync_edits: Phase C Nudge failed for clip "
                        .. "%s: %s", tostring(entry.clip_id),
                        tostring(err))
                end
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
                 or state.phaseA_status == "ran_ok"
                 or state.phaseB_status == "ran_ok"
                 or state.phaseC_status == "ran_ok") then
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

-- Phase D: partition `to_apply` into dispatch-runnable entries and
-- shape-failed entries. An entry is decomposable into Phase B (trim)
-- + Phase C (Nudge) verbs iff Δrecord_dur == Δsource_out − Δsource_in
-- (the record_start residual after B is exactly the Phase C nudge
-- amount M = Δrecord_start − Δsource_in; M is unconstrained). Anything
-- else (speed change, slip + duration-extend, anything where the
-- record-duration delta doesn't match the trim-only contribution) is
-- not representable as the closed verb set and gets surfaced
-- immediately as skipped[unknown_delta_shape] — no dispatch, no clip
-- mutation. Per data-model.md §apply step 12 / `Closed-set reasons`.
local function surface_shape_failures(to_apply_entries, result)
    local runnable = {}
    for _, entry in ipairs(to_apply_entries) do
        local live = entry.live
        local cur  = entry.current
        local dsi = live.source_in  - cur.source_in
        local dso = live.source_out - cur.source_out
        local drd = live.record_dur - cur.record_dur
        if drd == (dso - dsi) then
            table.insert(runnable, entry)
        else
            table.insert(result.skipped, {
                clip_id         = entry.clip_id,
                resolve_item_id = entry.resolve_item_id,
                reason          = "unknown_delta_shape",
            })
        end
    end
    return runnable
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
--- V1 MVP scope: Phase 0 (`MoveClipToTrack`) + Phase A
--- (`ToggleClipEnabled`) + Phase B (`OverwriteTrimEdge` per nonzero
--- edge delta — Δsource_in left, Δsource_out right) + Phase C
--- (`Nudge` for residual record_start shift M = Δrecord_start −
--- Δsource_in) + Phase D (surface non-decomposable residuals as
--- skipped[unknown_delta_shape], no dispatch) + bootstrap fingerprint
--- persist + V1 no-modal conflict surface. Decomposability gate:
--- Δrecord_dur == Δsource_out − Δsource_in.
function M.apply(response, sequence_id, project_id, db, user_choices)
    assert(type(project_id) == "string" and project_id ~= "",
        "sync_edits.apply: project_id required")
    assert(user_choices == nil,
        "sync_edits.apply: user_choices is V2 only; V1 MVP must pass "
        .. "nil (conflicts surface as skipped with reason "
        .. "no_modal_v1_unhandled_conflict)")

    -- M.apply consumes the classifier-shape response (per-item
    -- `track_id` in JVE namespace). The wire→classifier translation
    -- (`M.translate_wire_response`) is the responsibility of the caller
    -- — `M.execute` runs it on the helper response before invoking
    -- M.apply, and tests can either pass classifier shape directly or
    -- call translate_wire_response first.
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

    -- Phase D first: partition runnable entries from shape-failed
    -- (non-decomposable) entries. Shape-failed entries are surfaced as
    -- skipped[unknown_delta_shape] now and never enter dispatch.
    local runnable = surface_shape_failures(classified.to_apply, result)
    if #runnable == 0 then return result end

    local per_clip = init_per_clip(runnable)
    -- with_undo_group brackets the four phase runs symmetrically (M#5):
    -- any phase-internal assert rolls back the savepoint + in-memory
    -- mutations and closes the group before re-raising, instead of
    -- leaving the group open to poison subsequent commands.
    command_manager.with_undo_group("Sync Edits from Resolve", function()
        run_phase_0(runnable, per_clip, project_id, sequence_id, result)
        run_phase_a(runnable, per_clip, project_id, sequence_id, result)
        run_phase_b(runnable, per_clip, project_id, sequence_id, result)
        run_phase_c(runnable, per_clip, project_id, sequence_id, result)
    end)

    finalize_per_clip(per_clip, runnable, db, result)
    return result
end

--- Full command path: pulls the live timeline via the helper, runs
--- M.apply, fires `on_complete`. Mirrors SyncGradesFromResolve.execute
--- (T031) — non-blocking; success / error surface through on_complete.
--- The inner phase dispatches happen inside the apply() undo group, so
--- the command itself is not separately undoable (one Cmd-Z reverts
--- the whole sync via the group entries).
-- `_command` accepted for register_executor's executor signature; not
-- used here because SyncEditsFromResolve is non-undoable at this
-- command level — its inner ripple/insert/delete commands carry the
-- undo entries.
function M.execute(args, db, _command)
    assert(type(args) == "table", "SyncEditsFromResolve: args required")
    assert(db, "SyncEditsFromResolve: db required (passed by register's "
        .. "executor closure; SQL isolation policy keeps "
        .. "the global DB lookup out of commands)")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "SyncEditsFromResolve: sequence_id required")
    assert(type(args.project_id) == "string" and args.project_id ~= "",
        "SyncEditsFromResolve: project_id required")
    assert(args.on_complete == nil or type(args.on_complete) == "function",
        "SyncEditsFromResolve: on_complete, when supplied, must be a "
        .. "function — terminal results also surface via the "
        .. "sync_edits_from_resolve_completed signal (FR-023).")
    assert(args.user_choices == nil or type(args.user_choices) == "table",
        "SyncEditsFromResolve: user_choices must be a table or nil")

    supervisor.with_client(notify, args, function(client)
        -- Auto-discovery (FR-011c): establish/repair the ledger join
        -- BEFORE classifying edits, so a freshly-imported project
        -- syncs without a separate user-run connect step. Discovery
        -- already pulls read_timeline (its position channel needs it),
        -- and its report hands the raw result back — reuse it instead
        -- of paying a second helper roundtrip. A rate mismatch skips
        -- only the position channel (surfaced below); the classify
        -- walk then proceeds on marker matches + persisted links.
        discovery.discover_and_link(client, args.sequence_id, db,
            function(report, code, message)
                if report == nil then
                    notify(args, nil, code, message)
                    return
                end
                discovery.log_discovery_warnings(
                    report, "SyncEditsFromResolve")
                -- The apply body asserts internal invariants (wire shape,
                -- per-item track_id, ledger consistency). The C++ socket
                -- boundary delivering this response SWALLOWS any Lua error
                -- raised here (logs+pops+continues, never re-raises — see
                -- bridge_completion.lua's contract and
                -- src/jve_lua_callback.h), so an un-caught assert would
                -- never reach notify(): sync_edits_from_resolve_completed
                -- would never fire and any in-progress indicator / awaited
                -- on_complete would strand (rule 2.32 silent failure).
                -- pcall the apply body and route a caught fault through the
                -- ONE terminal path as a loud failure — apply_failed,
                -- distinct from resolve_api_error (rule 2.21).
                local ok, result = pcall(function()
                    -- Wire→classifier translation at the boundary between
                    -- the helper response and JVE-side processing. M.apply
                    -- consumes classifier shape (per-item JVE track_id).
                    local translated = M.translate_wire_response(
                        report.read_timeline_result, args.sequence_id)
                    local r = M.apply(translated, args.sequence_id,
                        args.project_id, db, args.user_choices)
                    -- What auto-discovery just (un)linked — surfaced
                    -- alongside the edit buckets (FR-011c report-not-skip).
                    r.discovery = {
                        matched        = report.matched,
                        already_linked = report.already_linked,
                        unmatched      = report.unmatched,
                        ambiguous      = report.ambiguous,
                        audio_skipped  = report.audio_skipped,
                        rate_mismatch  = report.rate_mismatch,
                        stamped        = report.stamped,
                        stamp_skipped  = report.stamp_skipped,
                        stamp_failures = report.stamp_failures,
                    }
                    return r
                end)
                if not ok then
                    notify(args, nil, "apply_failed", tostring(result))
                    return
                end
                notify(args, result, nil, nil)
            end)
    end)
end

local SPEC = {
    -- Inner phase verbs are dispatched under a `begin_undo_group`, so
    -- one Cmd-Z reverts the whole sync. The outer command does not
    -- need its own undo entry — set undoable=false to avoid a phantom
    -- entry that would be a no-op for the user.
    undoable      = false,
    mutates_clips = true,
    args = {
        sequence_id  = { required = true,  kind = "string" },
        project_id   = { required = true,  kind = "string" },
        on_complete  = { required = false, kind = "function" },
        user_choices = { required = false, kind = "table" },
    },
}

M.register = OP.make_register(M.execute, SPEC)

return M
