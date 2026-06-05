-- spec 023 FR-015 regression — fidelity = "none" for ungraded Resolve
-- items. The "Resolve emits CDL for every clip" assumption was
-- disproved by the Anamnesis sequence (1202 video items, at least one
-- with no ASC_SOP/ASC_SAT block in the EDL export). An item the
-- helper SAW but observed to have no grade is distinct from an item
-- that was ABSENT (FR-013a item-deleted case):
--
--   item ABSENT  (not in response.grades)  → FR-013a stale walk
--                                            (prior grade kept, stale=1)
--   item PRESENT, fidelity="none"          → drop the JVE clip_grade row
--                                            (user removed grade in Resolve;
--                                            re-sync overwrites per FR-014)
--
-- Both branches are undoable.

require("test_env")

local database          = require("core.database")
local ClipGrade         = require("models.clip_grade")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local sync_grades       = require("core.commands.sync_grades_from_resolve")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== SyncGradesFromResolve fidelity=none Tests ===")

local db_path = "/tmp/jve/test_sync_grades_fidelity_none.db"
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
    -- c_graded: previously had a grade synced; user removes grade in
    --           Resolve. Helper now sees the item, observes no CDL.
    -- c_naked:  never had a grade. Helper sees it, observes no CDL.
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('c_graded', 'p', 'G', 't', 's', 's',  0, 96, 0, 96,
        NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
           ('c_naked',  'p', 'N', 't', 's', 's', 96, 96, 0, 96,
        NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now))

identity_ledger.upsert("c_graded", { resolve_item_id = "live_g" }, db)
identity_ledger.upsert("c_naked",  { resolve_item_id = "live_n" }, db)

-- Prior grade for c_graded only.
local PRIOR_CDL = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r  = 1.10, power_g  = 1.0,  power_b  = 0.95,
    saturation = 0.85,
}
ClipGrade.upsert("c_graded", {
    cdl = PRIOR_CDL, lut_ref = nil, fidelity = "primary",
    source = "resolve", stale = 0, synced_at = now,
}, db)

-- ─── Helper response: both items PRESENT with fidelity="none" ──────
-- Resolve still has both items; user just removed grades. Per Option 2
-- the helper emits them with fidelity="none" rather than omitting
-- (omission means FR-013a item-absent — a different scenario).
local response = {
    grades = {
        { resolve_item_id = "live_g", fidelity = "none" },
        { resolve_item_id = "live_n", fidelity = "none" },
    },
}
local captured = sync_grades.apply(response, "s", db, now + 60)

-- ─── c_graded's prior grade was dropped (re-sync overwrite per FR-014) ──
check("c_graded grade row dropped after fidelity=none",
    ClipGrade.load("c_graded", db) == nil)
-- ─── c_naked stays ungraded (no row to drop, no error) ─────────────
check("c_naked stays ungraded after fidelity=none (no prior row)",
    ClipGrade.load("c_naked", db) == nil)

-- ─── Captured carries the prior c_graded row so undo restores it ──
local has_graded_capture = false
for _, e in ipairs(captured.entries) do
    if e.clip_id == "c_graded" and e.before ~= nil
        and e.before.cdl
        and e.before.cdl.slope_r == PRIOR_CDL.slope_r then
        has_graded_capture = true
    end
end
check("apply captured c_graded's prior CDL for undo",
    has_graded_capture)

-- ─── Restore brings the prior grade back ──────────────────────────
sync_grades.restore(captured, db)
local restored = ClipGrade.load("c_graded", db)
check("restore brings c_graded's prior CDL back",
    restored ~= nil and restored.cdl
        and restored.cdl.slope_r == PRIOR_CDL.slope_r)
check("restore leaves c_naked still ungraded",
    ClipGrade.load("c_naked", db) == nil)

-- ─── Mixed batch: one fidelity=none, one fidelity=primary ─────────
ClipGrade.upsert("c_graded", {  -- reset prior state
    cdl = PRIOR_CDL, lut_ref = nil, fidelity = "primary",
    source = "resolve", stale = 0, synced_at = now,
}, db)
local NEW_CDL = {
    slope_r = 0.92, slope_g = 1.04, slope_b = 1.12,
    offset_r = -0.03, offset_g = 0.02, offset_b = 0.04,
    power_r  = 0.98, power_g  = 1.06, power_b  = 1.01,
    saturation = 1.12,
}
local mixed = {
    grades = {
        { resolve_item_id = "live_g", fidelity = "none" },
        { resolve_item_id = "live_n", cdl = NEW_CDL,
          fidelity = "primary" },
    },
}
local cap2 = sync_grades.apply(mixed, "s", db, now + 120)
check("mixed batch: c_graded grade row dropped",
    ClipGrade.load("c_graded", db) == nil)
local naked_after = ClipGrade.load("c_naked", db)
check("mixed batch: c_naked picks up the primary CDL",
    naked_after ~= nil and naked_after.cdl
        and naked_after.cdl.saturation == NEW_CDL.saturation)

-- Restore undoes both branches.
sync_grades.restore(cap2, db)
check("mixed batch undo: c_graded restored to PRIOR_CDL",
    ClipGrade.load("c_graded", db) ~= nil)
check("mixed batch undo: c_naked back to ungraded",
    ClipGrade.load("c_naked", db) == nil)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_sync_grades_fidelity_none.lua: failures present")
print("✅ test_sync_grades_fidelity_none.lua passed")
