-- spec 023 quickstart §1b regression — ledger-driven grade attribution
-- (FR-021: helper holds no JVE state; FR-011c: connect by position is
-- enough for the first sync, marker stamping is durability for
-- subsequent Resolve-side mutations, not a sync prerequisite).
--
-- The user-visible flow this test pins:
--   1. JVE imports a graded DRP (clips get adopted Sm2Ti DbIds as
--      clip.id, OR fresh UUIDs for blades made after import).
--   2. Sync-time auto-discovery runs positional match (no markers
--      exist in live Resolve yet — first sync after import).
--      identity_ledger gains a row per matched clip mapping
--      clip.id → live resolve_item_id (= TimelineItem:GetUniqueId(),
--      NOT the DRP DbId — see spec.md T047 spike).
--   3. SyncGradesFromResolve pulls grades. The helper returns rows
--      keyed by its native resolve_item_id. The Lua side joins to
--      clip.id via identity_ledger.
--
-- Before the architectural fix this test ratifies, the helper keyed
-- rows on `jve_guid` recovered from customData markers — so a sync
-- after positional-only connect returned ZERO grades regardless of
-- how many ledger rows existed. This test would FAIL pre-fix and
-- PASSES post-fix.

require("test_env")

local database          = require("core.database")
local ClipGrade         = require("models.clip_grade")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local sync_grades       = require("core.commands.sync_grades_from_resolve")
local command_manager   = require("core.command_manager")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== SyncGradesFromResolve ledger-attribution Tests ===")

local db_path = "/tmp/jve/test_sync_grades_ledger_attribution.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings,
                          created_at, modified_at)
    VALUES ('p', 'P', 'resample',
        '{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}',
        %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame,
        view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    -- Two clips: one with an adopted DbId (clip.id == its DRP DbId
    -- but that's a JVE-side fact; live API doesn't know it). One
    -- with a fresh UUID (a blade JVE made after import). Both have
    -- ledger rows mapping to runtime resolve_item_ids.
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('dbid_clip_a', 'p', 'A', 't', 's', 's',  0, 96, 0, 96,
        NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
           ('uuid_blade_b', 'p', 'B', 't', 's', 's', 96, 96, 0, 96,
        NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now))

-- Sync-time auto-discovery populated these ledger rows by positional
-- match (FR-011c). Note: resolve_item_id values are RUNTIME handles
-- from GetUniqueId(), NOT equal to clip.id even when clip.id is the
-- adopted DbId (spec.md T047 spike: 0/1003 match).
identity_ledger.upsert("dbid_clip_a",
    { resolve_item_id = "live_uid_111" }, db)
identity_ledger.upsert("uuid_blade_b",
    { resolve_item_id = "live_uid_222" }, db)

command_manager.init("s", "p")

-- ─── Helper response shape (post-fix): keyed on resolve_item_id ─────
-- Helper has no JVE state (FR-021) — it returns its native ids.
local CDL_A = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r  = 1.10, power_g  = 1.0,  power_b  = 0.95,
    saturation = 0.85,
}
local CDL_B = {
    slope_r = 0.92, slope_g = 1.04, slope_b = 1.12,
    offset_r = -0.03, offset_g = 0.02, offset_b = 0.04,
    power_r  = 0.98, power_g  = 1.06, power_b  = 1.01,
    saturation = 1.12,
}

local to_wire = require("synthetic.helpers.grade_wire").cdl_model_to_wire
local response = {
    grades = {
        { resolve_item_id = "live_uid_111", cdl = to_wire(CDL_A),
          fidelity = "primary", lut = nil },
        { resolve_item_id = "live_uid_222", cdl = to_wire(CDL_B),
          fidelity = "primary", lut = nil },
    },
}

sync_grades.apply(response, "s", db, now + 60)

-- ─── Attribution lands on the right clips via the ledger ────────────
local grade_a = ClipGrade.load("dbid_clip_a", db)
check("ledger-attributed clip A has grade",  grade_a ~= nil)
check("clip A took CDL_A slope_r (not CDL_B, not nil)",
    grade_a and grade_a.cdl and grade_a.cdl.slope_r == CDL_A.slope_r)

local grade_b = ClipGrade.load("uuid_blade_b", db)
check("ledger-attributed clip B has grade",  grade_b ~= nil)
check("clip B took CDL_B saturation (not CDL_A, not nil)",
    grade_b and grade_b.cdl and grade_b.cdl.saturation == CDL_B.saturation)

-- Both rows have source 'resolve' per existing apply() contract.
check("clip A source = resolve",
    grade_a and grade_a.source == "resolve")
check("clip B source = resolve",
    grade_b and grade_b.source == "resolve")

-- ─── Undo via command_manager unwinds apply ───────────────────────
local undo_result = command_manager.undo()
check("command_manager.undo() succeeds", undo_result and undo_result.success)
check("undo removes clip A grade row (was ungraded before)",
    ClipGrade.load("dbid_clip_a", db) == nil)
check("undo removes clip B grade row (was ungraded before)",
    ClipGrade.load("uuid_blade_b", db) == nil)

-- ─── Unmatched-from-Resolve: a helper row whose resolve_item_id has
-- no ledger entry must be REPORTED, not silently dropped (FR-011c
-- "Unmatched clips MUST be reported, not silently skipped" — same
-- discipline applies in the Resolve→JVE direction). The caller can
-- decide what to do (typically: log "colorist added a clip Resolve-
-- side after import; reconnect to pick it up").
local response_with_unknown = {
    grades = {
        { resolve_item_id = "live_uid_111", cdl = to_wire(CDL_A),
          fidelity = "primary", lut = nil },
        { resolve_item_id = "live_uid_999", cdl = to_wire(CDL_B),  -- no ledger entry
          fidelity = "primary", lut = nil },
    },
}
local summary2 = sync_grades.apply(response_with_unknown, "s", db, now + 120)
check("known resolve_item_id still attributed",
    ClipGrade.load("dbid_clip_a", db) ~= nil)
check("unknown resolve_item_id surfaced as unmatched",
    type(summary2.unmatched_resolve_items) == "table"
        and #summary2.unmatched_resolve_items == 1
        and summary2.unmatched_resolve_items[1] == "live_uid_999")

-- Undo unwinds known apply; unmatched are no-ops on undo (nothing was
-- written for them).
local undo2 = command_manager.undo()
check("undo after unmatched-mixed batch succeeds",
    undo2 and undo2.success)
check("undo after unmatched-mixed batch clears the known clip's row",
    ClipGrade.load("dbid_clip_a", db) == nil)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_sync_grades_ledger_attribution.lua: failures present")
print("✅ test_sync_grades_ledger_attribution.lua passed")
