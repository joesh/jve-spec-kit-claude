-- sync_edits_from_resolve.apply — black-box dispatch contract test
-- (spec 023 FR-024 / FR-025; data-model.md §SyncEditsFromResolve —
-- classification + dispatch contract, V1 MVP).
--
-- Feeds apply() a synthetic read_timeline response built to
-- helper-protocol.md §read_timeline's exact shape; asserts observable
-- outcomes — DB state (clip.track_id, clip.enabled, ledger fingerprint)
-- and the result buckets (applied, failed, skipped, fingerprints_persisted).
--
-- Currently wired: bootstrap fp persist, V1 no-modal conflict surface,
-- Phase 0 (MoveClipToTrack), Phase A (ToggleClipEnabled). Phases B/C/D
-- not yet dispatched.

require("test_env")

local identity_ledger = require("core.resolve_bridge.identity_ledger")
local edit_diff       = require("core.resolve_bridge.edit_diff")
local sync_edits      = require("core.commands.sync_edits_from_resolve")
local ripple_layout   = require("synthetic.helpers.ripple_layout")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== sync_edits.apply Tests ===")

-- Two video tracks (v1, v2) come from ripple_layout's defaults.
-- Phase B trim clips live on v2 with wide separation so OverwriteTrim's
-- occlusion resolver doesn't touch unrelated fixture clips.
local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_sync_edits_apply.db",
    clips = {
        order = {"c_boot", "c_conflict", "c_move",
                 "c_disable", "c_move_and_disable",
                 "c_trim_right", "c_trim_left", "c_trim_both",
                 "c_move_only", "c_trim_and_move", "c_shape_fail"},
        c_boot = {
            id = "c_boot", name = "Bootstrap",
            track_key = "v1", media_key = "main",
            sequence_start = 100, duration = 200, source_in = 1000,
        },
        c_conflict = {
            id = "c_conflict", name = "Conflict",
            track_key = "v1", media_key = "main",
            sequence_start = 400, duration = 200, source_in = 2000,
        },
        c_move = {
            id = "c_move", name = "Move",
            track_key = "v1", media_key = "main",
            sequence_start = 700, duration = 200, source_in = 3000,
        },
        -- Phase A scenarios:
        c_disable = {
            id = "c_disable", name = "Disable",
            track_key = "v1", media_key = "main",
            sequence_start = 1000, duration = 200, source_in = 4000,
        },
        c_move_and_disable = {
            id = "c_move_and_disable", name = "MoveAndDisable",
            track_key = "v1", media_key = "main",
            sequence_start = 1300, duration = 200, source_in = 5000,
        },
        -- Phase B scenarios — placed on v2, wide separation:
        c_trim_right = {
            id = "c_trim_right", name = "TrimRight",
            track_key = "v2", media_key = "main",
            sequence_start = 2000, duration = 300, source_in = 6000,
        },
        c_trim_left = {
            id = "c_trim_left", name = "TrimLeft",
            track_key = "v2", media_key = "main",
            sequence_start = 2500, duration = 300, source_in = 7000,
        },
        c_trim_both = {
            id = "c_trim_both", name = "TrimBoth",
            track_key = "v2", media_key = "main",
            sequence_start = 3000, duration = 300, source_in = 8000,
        },
        -- Phase C scenarios (Nudge for residual record_start shift):
        c_move_only = {
            id = "c_move_only", name = "MoveOnly",
            track_key = "v2", media_key = "main",
            sequence_start = 3500, duration = 200, source_in = 9000,
        },
        c_trim_and_move = {
            id = "c_trim_and_move", name = "TrimAndMove",
            track_key = "v2", media_key = "main",
            sequence_start = 4000, duration = 300, source_in = 10000,
        },
        -- Phase D scenario (non-decomposable residual surfaces as
        -- skipped[unknown_delta_shape]; no dispatch):
        c_shape_fail = {
            id = "c_shape_fail", name = "ShapeFail",
            track_key = "v2", media_key = "main",
            sequence_start = 4500, duration = 200, source_in = 11000,
        },
    },
})
local db = layout.db

local function current_fp(clip_id)
    local Clip = require("models.clip")
    local clip = Clip.load(clip_id)
    return edit_diff.fingerprint{
        source_in    = clip.source_in,
        source_out   = clip.source_out,
        record_start = clip.sequence_start,
        record_dur   = clip.duration,
        enabled      = clip.enabled,
    }
end

----------------------------------------------------------------------
-- Scenario 1: empty response with NO ledger rows seeded yet → empty
-- result. Ledger walk has nothing to find, classify_all produces no
-- buckets, apply is a no-op.
----------------------------------------------------------------------
local r1 = sync_edits.apply({ items = {} }, layout.sequence_id,
    layout.project_id, db)
check("empty: result table shape",
    type(r1) == "table" and type(r1.applied) == "table"
    and type(r1.failed) == "table" and type(r1.skipped) == "table"
    and type(r1.fingerprints_persisted) == "table")
check("empty: applied empty",                 #r1.applied == 0)
check("empty: failed empty",                  #r1.failed == 0)
check("empty: skipped empty",                 #r1.skipped == 0)
check("empty: fingerprints_persisted empty",  #r1.fingerprints_persisted == 0)

-- Ledger setup:
--   c_boot:     no edit_fp (bootstrap path)
--   c_conflict: edit_fp baseline; we'll diverge JVE locally below so
--               classify_all produces kind=both → no-modal-skip.
--   c_move:     edit_fp matches current (no edit residual; only track
--               will differ in response → requires_track_move).
identity_ledger.upsert("c_boot",
    { resolve_item_id = "rs-c_boot" }, db)
identity_ledger.upsert("c_conflict",
    { resolve_item_id = "rs-c_conflict",
      edit_fingerprint = current_fp("c_conflict") }, db)
identity_ledger.upsert("c_move",
    { resolve_item_id = "rs-c_move",
      edit_fingerprint = current_fp("c_move") }, db)
-- Phase A clips: fp matches current; only Δenabled in response will
-- drive Phase A. c_move_and_disable adds Δtrack → Phase 0 + Phase A
-- both fire.
identity_ledger.upsert("c_disable",
    { resolve_item_id = "rs-c_disable",
      edit_fingerprint = current_fp("c_disable") }, db)
identity_ledger.upsert("c_move_and_disable",
    { resolve_item_id = "rs-c_move_and_disable",
      edit_fingerprint = current_fp("c_move_and_disable") }, db)
-- Phase B clips: fp matches current; live will diverge geometrically
-- in scenario 5 to drive OverwriteTrimEdge.
identity_ledger.upsert("c_trim_right",
    { resolve_item_id = "rs-c_trim_right",
      edit_fingerprint = current_fp("c_trim_right") }, db)
identity_ledger.upsert("c_trim_left",
    { resolve_item_id = "rs-c_trim_left",
      edit_fingerprint = current_fp("c_trim_left") }, db)
identity_ledger.upsert("c_trim_both",
    { resolve_item_id = "rs-c_trim_both",
      edit_fingerprint = current_fp("c_trim_both") }, db)
-- Phase C / D clips: fp matches current.
identity_ledger.upsert("c_move_only",
    { resolve_item_id = "rs-c_move_only",
      edit_fingerprint = current_fp("c_move_only") }, db)
identity_ledger.upsert("c_trim_and_move",
    { resolve_item_id = "rs-c_trim_and_move",
      edit_fingerprint = current_fp("c_trim_and_move") }, db)
identity_ledger.upsert("c_shape_fail",
    { resolve_item_id = "rs-c_shape_fail",
      edit_fingerprint = current_fp("c_shape_fail") }, db)

-- Diverge c_conflict locally (move record_start +50). This rebuilds the
-- in-memory timeline_state too if we go through a command, but for a
-- pure fixture tweak the DB update is fine — apply() reads via Clip.load.
db:exec("UPDATE clips SET sequence_start_frame = 450 WHERE id = 'c_conflict';")

----------------------------------------------------------------------
-- Scenario 2: three-row response covering bootstrap, conflict, move.
----------------------------------------------------------------------
local response = { items = {
    -- c_boot: live == current; no prior edit_fp → bootstrapped skip,
    -- fingerprint must be persisted outside the undo group.
    { resolve_item_id = "rs-c_boot", track_id = layout.tracks.v1.id,
      source_in = 1000, source_out = 1200,
      record_start = 100, record_duration = 200, enabled = true },
    -- c_conflict: live differs AND current diverged from stored →
    -- kind=both → conflict → V1 no-modal surfaces as skipped.
    { resolve_item_id = "rs-c_conflict", track_id = layout.tracks.v1.id,
      source_in = 2000, source_out = 2150,
      record_start = 400, record_duration = 150, enabled = true },
    -- c_move: track changed v1 → v2; no edit-diff residual on geometric
    -- fields (source/record match current). Phase 0 MoveClipToTrack
    -- should dispatch, succeed, persist fp.
    { resolve_item_id = "rs-c_move", track_id = layout.tracks.v2.id,
      source_in = 3000, source_out = 3200,
      record_start = 700, record_duration = 200, enabled = true },
} }

local r2 = sync_edits.apply(response, layout.sequence_id,
    layout.project_id, db)

local function find(list, clip_id)
    for _, e in ipairs(list) do
        if e.clip_id == clip_id then return e end
    end
    return nil
end

----------------------------------------------------------------------
-- Bootstrap persist (Scenario 2a)
----------------------------------------------------------------------
local link_boot = identity_ledger.load("c_boot", db)
check("c_boot: edit_fp persisted after bootstrap",
    link_boot ~= nil and link_boot.edit_fingerprint ~= nil
    and link_boot.edit_fingerprint ~= "")
check("c_boot: persisted fp matches current",
    link_boot and link_boot.edit_fingerprint == current_fp("c_boot"))
local persisted_boot = find(r2.fingerprints_persisted, "c_boot")
check("c_boot: appears in fingerprints_persisted",
    persisted_boot ~= nil)
check("c_boot: not in applied (no dispatch needed)",
    find(r2.applied, "c_boot") == nil)
check("c_boot: not in failed",
    find(r2.failed, "c_boot") == nil)

----------------------------------------------------------------------
-- V1 no-modal conflict surface (Scenario 2b)
----------------------------------------------------------------------
local skipped_conflict = find(r2.skipped, "c_conflict")
check("c_conflict: in skipped",
    skipped_conflict ~= nil)
check("c_conflict: reason=no_modal_v1_unhandled_conflict",
    skipped_conflict and
    skipped_conflict.reason == "no_modal_v1_unhandled_conflict")
check("c_conflict: not dispatched",
    find(r2.applied, "c_conflict") == nil
    and find(r2.failed, "c_conflict") == nil)
-- Conflict clip's stored fingerprint MUST NOT be overwritten — next
-- sync should re-detect divergence (regression: silent fp updates would
-- swallow the conflict). We seeded with the PRE-tweak fp
-- (sequence_start=400); after the local tweak current_fp is for
-- sequence_start=450 — so stored ≠ current is proof of "no overwrite."
do
    local link_conflict = identity_ledger.load("c_conflict", db)
    local seeded = link_conflict and link_conflict.edit_fingerprint
    check("c_conflict: stored fp ≠ current (proof we didn't overwrite)",
        seeded ~= nil and seeded ~= current_fp("c_conflict"))
end

----------------------------------------------------------------------
-- Phase 0 track move success (Scenario 2c)
----------------------------------------------------------------------
local Clip = require("models.clip")
local moved = Clip.load("c_move")
check("c_move: DB shows clip on target track v2",
    moved and moved.track_id == layout.tracks.v2.id)
local applied_move = find(r2.applied, "c_move")
check("c_move: in applied list",
    applied_move ~= nil)
check("c_move: applied entry records verb=MoveClipToTrack",
    applied_move and applied_move.attempted_verbs ~= nil
    and applied_move.attempted_verbs[1] == "MoveClipToTrack")
check("c_move: not in failed",
    find(r2.failed, "c_move") == nil)
check("c_move: not in skipped",
    find(r2.skipped, "c_move") == nil)
local link_move = identity_ledger.load("c_move", db)
check("c_move: ledger fp persisted post-success",
    link_move and link_move.edit_fingerprint == current_fp("c_move"))
local persisted_move = find(r2.fingerprints_persisted, "c_move")
check("c_move: appears in fingerprints_persisted",
    persisted_move ~= nil)

----------------------------------------------------------------------
-- Scenario 3: Phase A (ToggleClipEnabled) — T054b-2.
-- c_disable: live.enabled = false, current = true → Phase A only.
-- c_move_and_disable: live track v2, live.enabled = false → Phase 0
--                     then Phase A; applied entry must record both
--                     verbs in dispatch order (0 before A).
----------------------------------------------------------------------
local response_a = { items = {
    { resolve_item_id = "rs-c_disable", track_id = layout.tracks.v1.id,
      source_in = 4000, source_out = 4200,
      record_start = 1000, record_duration = 200, enabled = false },
    { resolve_item_id = "rs-c_move_and_disable",
      track_id = layout.tracks.v2.id,
      source_in = 5000, source_out = 5200,
      record_start = 1300, record_duration = 200, enabled = false },
    -- Pre-apply ledger walk would emit deleted_in_resolve conflicts for
    -- all OTHER seeded clips. Carry them through identical to current
    -- to keep the response self-consistent — only the two A-scenario
    -- clips should drive dispatches.
    { resolve_item_id = "rs-c_boot", track_id = layout.tracks.v1.id,
      source_in = 1000, source_out = 1200,
      record_start = 100, record_duration = 200, enabled = true },
    -- c_conflict is intentionally omitted (already diverged + handled
    -- in scenario 2; ledger walk surfaces it as deleted_in_resolve →
    -- result.skipped, fine).
    -- c_move now lives on v2 after scenario 2; carry its current
    -- state so classify_all sees no delta.
    { resolve_item_id = "rs-c_move", track_id = layout.tracks.v2.id,
      source_in = 3000, source_out = 3200,
      record_start = 700, record_duration = 200, enabled = true },
} }

local r3 = sync_edits.apply(response_a, layout.sequence_id,
    layout.project_id, db)

-- Phase A only: c_disable
local disabled = Clip.load("c_disable")
check("c_disable: DB shows enabled=false",
    disabled and disabled.enabled == false)
local applied_disable = find(r3.applied, "c_disable")
check("c_disable: in applied list",
    applied_disable ~= nil)
check("c_disable: applied verbs = [ToggleClipEnabled]",
    applied_disable and #applied_disable.attempted_verbs == 1
    and applied_disable.attempted_verbs[1] == "ToggleClipEnabled")
check("c_disable: not in failed",
    find(r3.failed, "c_disable") == nil)
local link_disable = identity_ledger.load("c_disable", db)
check("c_disable: ledger fp persisted",
    link_disable and link_disable.edit_fingerprint
    == current_fp("c_disable"))

-- Phase 0 + Phase A: c_move_and_disable
local moved_disabled = Clip.load("c_move_and_disable")
check("c_move_and_disable: DB shows track=v2",
    moved_disabled and moved_disabled.track_id == layout.tracks.v2.id)
check("c_move_and_disable: DB shows enabled=false",
    moved_disabled and moved_disabled.enabled == false)
local applied_combo = find(r3.applied, "c_move_and_disable")
check("c_move_and_disable: in applied list",
    applied_combo ~= nil)
check("c_move_and_disable: verbs = [MoveClipToTrack, ToggleClipEnabled]",
    applied_combo and #applied_combo.attempted_verbs == 2
    and applied_combo.attempted_verbs[1] == "MoveClipToTrack"
    and applied_combo.attempted_verbs[2] == "ToggleClipEnabled")
local link_combo = identity_ledger.load("c_move_and_disable", db)
check("c_move_and_disable: ledger fp persisted post-success",
    link_combo and link_combo.edit_fingerprint
    == current_fp("c_move_and_disable"))

----------------------------------------------------------------------
-- Scenario 4: Phase B — OverwriteTrimEdge trim decomposition.
--
-- For a forward clip, edges decompose as:
--   LEFT  edge by L: Δsource_in=+L, Δsource_out=0,  Δrecord_start=+L, Δrecord_dur=-L
--   RIGHT edge by R: Δsource_in=0,  Δsource_out=+R, Δrecord_start=0,  Δrecord_dur=+R
-- Combining: L = Δsource_in, R = Δsource_out, Δrecord_dur = R - L.
-- Phase B dispatches OverwriteTrimEdge per nonzero edge.
----------------------------------------------------------------------

-- c_trim_right: right-edge trim in by 50 source frames.
-- live.source_out = 6300 - 50 = 6250; live.record_dur = 250.
-- c_trim_left:  left-edge trim in by 30 source frames.
-- live.source_in = 7000 + 30 = 7030; live.record_start = 2530;
-- live.record_dur = 270.
-- c_trim_both:  left +20, right -40.
-- live.source_in = 8020; live.source_out = 8260; live.record_start = 3020;
-- live.record_dur = 240.
local response_b = { items = {
    { resolve_item_id = "rs-c_trim_right", track_id = layout.tracks.v2.id,
      source_in = 6000, source_out = 6250,
      record_start = 2000, record_duration = 250, enabled = true },
    { resolve_item_id = "rs-c_trim_left", track_id = layout.tracks.v2.id,
      source_in = 7030, source_out = 7300,
      record_start = 2530, record_duration = 270, enabled = true },
    { resolve_item_id = "rs-c_trim_both", track_id = layout.tracks.v2.id,
      source_in = 8020, source_out = 8260,
      record_start = 3020, record_duration = 240, enabled = true },
    -- Carry already-converged clips through so the ledger walk does not
    -- emit deleted_in_resolve noise. Phases preceding should see no delta.
    { resolve_item_id = "rs-c_boot", track_id = layout.tracks.v1.id,
      source_in = 1000, source_out = 1200,
      record_start = 100, record_duration = 200, enabled = true },
    { resolve_item_id = "rs-c_move", track_id = layout.tracks.v2.id,
      source_in = 3000, source_out = 3200,
      record_start = 700, record_duration = 200, enabled = true },
    { resolve_item_id = "rs-c_disable", track_id = layout.tracks.v1.id,
      source_in = 4000, source_out = 4200,
      record_start = 1000, record_duration = 200, enabled = false },
    { resolve_item_id = "rs-c_move_and_disable",
      track_id = layout.tracks.v2.id,
      source_in = 5000, source_out = 5200,
      record_start = 1300, record_duration = 200, enabled = false },
} }

local r4 = sync_edits.apply(response_b, layout.sequence_id,
    layout.project_id, db)

-- c_trim_right: right-only
local trim_right = Clip.load("c_trim_right")
check("c_trim_right: DB source_out converged to live (6250)",
    trim_right and trim_right.source_out == 6250)
check("c_trim_right: DB source_in unchanged (6000)",
    trim_right and trim_right.source_in == 6000)
check("c_trim_right: DB sequence_start unchanged (2000)",
    trim_right and trim_right.sequence_start == 2000)
check("c_trim_right: DB duration converged to live (250)",
    trim_right and trim_right.duration == 250)
local applied_right = find(r4.applied, "c_trim_right")
check("c_trim_right: applied verbs = [OverwriteTrimEdge]",
    applied_right and #applied_right.attempted_verbs == 1
    and applied_right.attempted_verbs[1] == "OverwriteTrimEdge")
local link_trim_right = identity_ledger.load("c_trim_right", db)
check("c_trim_right: ledger fp persisted post-success",
    link_trim_right and link_trim_right.edit_fingerprint
    == current_fp("c_trim_right"))

-- c_trim_left: left-only
local trim_left = Clip.load("c_trim_left")
check("c_trim_left: DB source_in converged to live (7030)",
    trim_left and trim_left.source_in == 7030)
check("c_trim_left: DB source_out unchanged (7300)",
    trim_left and trim_left.source_out == 7300)
check("c_trim_left: DB sequence_start converged to live (2530)",
    trim_left and trim_left.sequence_start == 2530)
check("c_trim_left: DB duration converged to live (270)",
    trim_left and trim_left.duration == 270)
local applied_left = find(r4.applied, "c_trim_left")
check("c_trim_left: applied verbs = [OverwriteTrimEdge]",
    applied_left and #applied_left.attempted_verbs == 1
    and applied_left.attempted_verbs[1] == "OverwriteTrimEdge")

-- c_trim_both: left and right
local trim_both = Clip.load("c_trim_both")
check("c_trim_both: DB source_in converged (8020)",
    trim_both and trim_both.source_in == 8020)
check("c_trim_both: DB source_out converged (8260)",
    trim_both and trim_both.source_out == 8260)
check("c_trim_both: DB sequence_start converged (3020)",
    trim_both and trim_both.sequence_start == 3020)
check("c_trim_both: DB duration converged (240)",
    trim_both and trim_both.duration == 240)
local applied_both = find(r4.applied, "c_trim_both")
check("c_trim_both: applied records two trim dispatches",
    applied_both and #applied_both.attempted_verbs == 2
    and applied_both.attempted_verbs[1] == "OverwriteTrimEdge"
    and applied_both.attempted_verbs[2] == "OverwriteTrimEdge")

----------------------------------------------------------------------
-- Scenario 5: Phase C — Nudge for residual record_start shift after
-- (optional) Phase B trim. Decomposition: L = Δsource_in,
-- R = Δsource_out, M = Δrecord_start - L. Decomposable iff
-- Δrecord_dur == R - L; M is the leftover record_start shift Phase C
-- nudges by.
--
-- c_move_only:     pure move +40, no trim. → Nudge only.
-- c_trim_and_move: left-trim L=15 + move M=25. → Phase B left then C.
----------------------------------------------------------------------
local response_c = { items = {
    { resolve_item_id = "rs-c_move_only", track_id = layout.tracks.v2.id,
      source_in = 9000, source_out = 9200,
      record_start = 3540, record_duration = 200, enabled = true },
    { resolve_item_id = "rs-c_trim_and_move", track_id = layout.tracks.v2.id,
      source_in = 10015, source_out = 10300,
      record_start = 4040, record_duration = 285, enabled = true },
    -- Carry already-converged clips through to suppress
    -- deleted_in_resolve noise.
    { resolve_item_id = "rs-c_boot", track_id = layout.tracks.v1.id,
      source_in = 1000, source_out = 1200,
      record_start = 100, record_duration = 200, enabled = true },
    { resolve_item_id = "rs-c_move", track_id = layout.tracks.v2.id,
      source_in = 3000, source_out = 3200,
      record_start = 700, record_duration = 200, enabled = true },
    { resolve_item_id = "rs-c_disable", track_id = layout.tracks.v1.id,
      source_in = 4000, source_out = 4200,
      record_start = 1000, record_duration = 200, enabled = false },
    { resolve_item_id = "rs-c_move_and_disable",
      track_id = layout.tracks.v2.id,
      source_in = 5000, source_out = 5200,
      record_start = 1300, record_duration = 200, enabled = false },
    { resolve_item_id = "rs-c_trim_right", track_id = layout.tracks.v2.id,
      source_in = 6000, source_out = 6250,
      record_start = 2000, record_duration = 250, enabled = true },
    { resolve_item_id = "rs-c_trim_left", track_id = layout.tracks.v2.id,
      source_in = 7030, source_out = 7300,
      record_start = 2530, record_duration = 270, enabled = true },
    { resolve_item_id = "rs-c_trim_both", track_id = layout.tracks.v2.id,
      source_in = 8020, source_out = 8260,
      record_start = 3020, record_duration = 240, enabled = true },
} }

local r5 = sync_edits.apply(response_c, layout.sequence_id,
    layout.project_id, db)

-- c_move_only: pure record_start shift via Nudge
local moved_only = Clip.load("c_move_only")
check("c_move_only: DB sequence_start converged (3540)",
    moved_only and moved_only.sequence_start == 3540)
check("c_move_only: DB source_in unchanged (9000)",
    moved_only and moved_only.source_in == 9000)
check("c_move_only: DB source_out unchanged (9200)",
    moved_only and moved_only.source_out == 9200)
check("c_move_only: DB duration unchanged (200)",
    moved_only and moved_only.duration == 200)
local applied_move_only = find(r5.applied, "c_move_only")
check("c_move_only: applied verbs = [Nudge]",
    applied_move_only and #applied_move_only.attempted_verbs == 1
    and applied_move_only.attempted_verbs[1] == "Nudge")
local link_move_only = identity_ledger.load("c_move_only", db)
check("c_move_only: ledger fp persisted",
    link_move_only and link_move_only.edit_fingerprint
    == current_fp("c_move_only"))

-- c_trim_and_move: left-trim then Nudge, in that order
local trim_move = Clip.load("c_trim_and_move")
check("c_trim_and_move: DB source_in converged (10015)",
    trim_move and trim_move.source_in == 10015)
check("c_trim_and_move: DB source_out unchanged (10300)",
    trim_move and trim_move.source_out == 10300)
check("c_trim_and_move: DB sequence_start converged (4040)",
    trim_move and trim_move.sequence_start == 4040)
check("c_trim_and_move: DB duration converged (285)",
    trim_move and trim_move.duration == 285)
local applied_trim_move = find(r5.applied, "c_trim_and_move")
check("c_trim_and_move: verbs = [OverwriteTrimEdge, Nudge]",
    applied_trim_move and #applied_trim_move.attempted_verbs == 2
    and applied_trim_move.attempted_verbs[1] == "OverwriteTrimEdge"
    and applied_trim_move.attempted_verbs[2] == "Nudge")

----------------------------------------------------------------------
-- Scenario 6: Phase D — non-decomposable residual surfaces as
-- skipped[unknown_delta_shape]; no dispatch, no clip mutation.
--
-- c_shape_fail: Δsource_in=10, Δsource_out=10, Δrecord_start=0,
-- Δrecord_dur=20 — violates trim/move decomposition (Δrecord_dur ≠
-- Δsource_out − Δsource_in = 0). Could be a speed change or a slip+
-- duration-extend — not representable as Phase B/C verbs.
----------------------------------------------------------------------
local response_d = { items = {
    { resolve_item_id = "rs-c_shape_fail", track_id = layout.tracks.v2.id,
      source_in = 11010, source_out = 11210,
      record_start = 4500, record_duration = 220, enabled = true },
    -- Carry every other clip through at its current state to suppress
    -- ledger-walk noise.
    { resolve_item_id = "rs-c_boot", track_id = layout.tracks.v1.id,
      source_in = 1000, source_out = 1200,
      record_start = 100, record_duration = 200, enabled = true },
    { resolve_item_id = "rs-c_move", track_id = layout.tracks.v2.id,
      source_in = 3000, source_out = 3200,
      record_start = 700, record_duration = 200, enabled = true },
    { resolve_item_id = "rs-c_disable", track_id = layout.tracks.v1.id,
      source_in = 4000, source_out = 4200,
      record_start = 1000, record_duration = 200, enabled = false },
    { resolve_item_id = "rs-c_move_and_disable",
      track_id = layout.tracks.v2.id,
      source_in = 5000, source_out = 5200,
      record_start = 1300, record_duration = 200, enabled = false },
    { resolve_item_id = "rs-c_trim_right", track_id = layout.tracks.v2.id,
      source_in = 6000, source_out = 6250,
      record_start = 2000, record_duration = 250, enabled = true },
    { resolve_item_id = "rs-c_trim_left", track_id = layout.tracks.v2.id,
      source_in = 7030, source_out = 7300,
      record_start = 2530, record_duration = 270, enabled = true },
    { resolve_item_id = "rs-c_trim_both", track_id = layout.tracks.v2.id,
      source_in = 8020, source_out = 8260,
      record_start = 3020, record_duration = 240, enabled = true },
    { resolve_item_id = "rs-c_move_only", track_id = layout.tracks.v2.id,
      source_in = 9000, source_out = 9200,
      record_start = 3540, record_duration = 200, enabled = true },
    { resolve_item_id = "rs-c_trim_and_move", track_id = layout.tracks.v2.id,
      source_in = 10015, source_out = 10300,
      record_start = 4040, record_duration = 285, enabled = true },
} }

local r6 = sync_edits.apply(response_d, layout.sequence_id,
    layout.project_id, db)

local before_shape = Clip.load("c_shape_fail")
local skipped_shape = find(r6.skipped, "c_shape_fail")
check("c_shape_fail: in skipped",
    skipped_shape ~= nil)
check("c_shape_fail: reason=unknown_delta_shape",
    skipped_shape and skipped_shape.reason == "unknown_delta_shape")
check("c_shape_fail: NOT in applied (no dispatch)",
    find(r6.applied, "c_shape_fail") == nil)
check("c_shape_fail: NOT in failed",
    find(r6.failed, "c_shape_fail") == nil)
check("c_shape_fail: DB source_in unchanged (11000, no mutation)",
    before_shape and before_shape.source_in == 11000)
check("c_shape_fail: DB source_out unchanged (11200)",
    before_shape and before_shape.source_out == 11200)
check("c_shape_fail: DB sequence_start unchanged (4500)",
    before_shape and before_shape.sequence_start == 4500)
check("c_shape_fail: DB duration unchanged (200)",
    before_shape and before_shape.duration == 200)
-- Fingerprint must NOT be persisted (next sync should re-classify and
-- re-surface as Phase D until the user resolves out-of-band).
local link_shape = identity_ledger.load("c_shape_fail", db)
local seeded_shape_fp = link_shape and link_shape.edit_fingerprint
check("c_shape_fail: ledger fp unchanged (still equals current)",
    seeded_shape_fp ~= nil
    and seeded_shape_fp == current_fp("c_shape_fail"))

----------------------------------------------------------------------
-- Scenario 7: user_choices is V2; passing non-nil must assert.
----------------------------------------------------------------------
do
    local ok, err = pcall(sync_edits.apply,
        { items = {} }, layout.sequence_id, layout.project_id, db,
        { take_resolve = {} })
    check("user_choices non-nil: assert fires",
        not ok and tostring(err):match("user_choices") ~= nil)
end

----------------------------------------------------------------------
-- Scenario 9: M.register installs SyncEditsFromResolve into the
-- command_executors table and the SPEC declares correct arg metadata
-- (FR-023 — bridge actions invocable via command system).
----------------------------------------------------------------------
do
    local executors, undoers = {}, {}
    local function set_err(_msg) end
    local reg = sync_edits.register(executors, undoers, db, set_err)
    check("register: returns {executor, spec}",
        type(reg) == "table"
        and type(reg.executor) == "function"
        and type(reg.spec) == "table")
    check("register: installs SyncEditsFromResolve executor",
        type(executors["SyncEditsFromResolve"]) == "function")
    check("SPEC: required args (sequence_id, project_id); on_complete "
        .. "optional per FR-023 — menu/shortcut dispatch can't supply "
        .. "a callback, terminal results surface via the "
        .. "sync_edits_from_resolve_completed signal",
        reg.spec.args.sequence_id.required == true
        and reg.spec.args.project_id.required == true
        and reg.spec.args.on_complete.required == false)
    check("SPEC: user_choices is optional",
        reg.spec.args.user_choices.required == false)
    check("SPEC: undoable=false (inner group provides undo)",
        reg.spec.undoable == false)
end

----------------------------------------------------------------------
-- Scenario 10: missing project_id asserts (rule 2.29 / 1.14).
----------------------------------------------------------------------
do
    local ok, err = pcall(sync_edits.apply,
        { items = {} }, layout.sequence_id, nil, db)
    check("missing project_id: assert fires",
        not ok and tostring(err):match("project_id") ~= nil)
end

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
layout:cleanup()
assert(fail == 0, "test_sync_edits_apply.lua: failures present")
print("✅ test_sync_edits_apply.lua passed")
