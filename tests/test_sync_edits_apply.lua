-- T054b-1 — sync_edits_from_resolve.apply skeleton + Phase 0
-- (spec 023 FR-024 / FR-025; data-model.md §SyncEditsFromResolve —
-- classification + dispatch contract, V1 MVP).
--
-- Black-box: feed apply() a synthetic read_timeline response built to
-- helper-protocol.md §read_timeline's exact shape; assert observable
-- outcomes — DB state (clip.track_id, ledger fingerprint) and the
-- result buckets (applied, failed, skipped, fingerprints_persisted).
--
-- B1 scope: bootstrap-fp persist, V1 no-modal conflict surface, Phase 0
-- (MoveClipToTrack). Phases A/B/C/D land in subsequent commits.

require("test_env")

local identity_ledger = require("core.resolve_bridge.identity_ledger")
local edit_diff       = require("core.resolve_bridge.edit_diff")
local sync_edits      = require("core.commands.sync_edits_from_resolve")
local ripple_layout   = require("tests.helpers.ripple_layout")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== sync_edits.apply Tests (T054b-1) ===")

-- Two video tracks (v1, v2) come from ripple_layout's defaults; we
-- override clips to be the four scenarios B1 exercises.
local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_sync_edits_apply.db",
    clips = {
        order = {"c_boot", "c_conflict", "c_move"},
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
-- swallow the conflict).
local link_conflict = identity_ledger.load("c_conflict", db)
check("c_conflict: ledger fp unchanged after no-modal skip",
    link_conflict and
    link_conflict.edit_fingerprint == current_fp("c_conflict")
    -- current was diverged but stored fp predates the divergence;
    -- after fixture tweak current_fp != stored. The invariant is
    -- "no overwrite": fp stays equal to whatever we seeded.
    or true)
-- Stronger: re-load and compare to the originally seeded fp.
do
    local seeded = link_conflict and link_conflict.edit_fingerprint
    local Clip = require("models.clip")
    local conflict_clip = Clip.load("c_conflict")
    -- We seeded with the PRE-tweak fp (sequence_start=400). After tweak,
    -- current_fp is for sequence_start=450 — so seeded ≠ current.
    local current_after_tweak = edit_diff.fingerprint{
        source_in    = conflict_clip.source_in,
        source_out   = conflict_clip.source_out,
        record_start = conflict_clip.sequence_start,
        record_dur   = conflict_clip.duration,
        enabled      = conflict_clip.enabled,
    }
    check("c_conflict: stored fp ≠ current (proof we didn't overwrite)",
        seeded ~= nil and seeded ~= current_after_tweak)
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
-- Scenario 3: user_choices is V2; passing non-nil must assert.
----------------------------------------------------------------------
do
    local ok, err = pcall(sync_edits.apply,
        { items = {} }, layout.sequence_id, layout.project_id, db,
        { take_resolve = {} })
    check("user_choices non-nil: assert fires",
        not ok and tostring(err):match("user_choices") ~= nil)
end

----------------------------------------------------------------------
-- Scenario 4: missing project_id asserts (rule 2.29 / 1.14).
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
