-- spec 023 regression: SyncGradesFromResolve.restore() must revert
-- the identity_ledger grade_fingerprint that apply() writes.
--
-- Domain requirement: undo of a grade sync must leave the ledger in
-- exactly the state it was before the sync. If it doesn't, the NEXT
-- SyncGrades compares the stored post-apply fingerprint against the
-- reverted (pre-apply) grade data, classifies it as "Resolve-only"
-- drift, and silently re-applies the grade — defeating the undo.
--
-- This test FAILS before the fix (restore() omits ledger revert) and
-- PASSES after (captured.entries carry link_before; restore() reverts it).

require("test_env")

local database       = require("core.database")
local ClipGrade      = require("models.clip_grade")
local identity_ledger = require("core.resolve_bridge.identity_ledger")
local sync_grades    = require("core.commands.sync_grades_from_resolve")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== SyncGradesFromResolve: restore() reverts ledger fingerprint ===")

local db_path = "/tmp/jve/test_sync_grades_undo_reverts_ledger_fp.db"
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
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos,
        created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24000, 1001, 48000, 1920, 1080,
        0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('c1', 'p', 'clip1', 't', 's', 's', 0, 96, 0, 96, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now))

-- Seed a pre-existing grade with a known fingerprint.
local PRE_CDL = {
    slope_r = 1.1, slope_g = 0.9, slope_b = 1.0,
    offset_r = 0.02, offset_g = -0.01, offset_b = 0.0,
    power_r  = 0.95, power_g = 1.05, power_b = 1.0,
    saturation = 0.9,
}
ClipGrade.upsert("c1", {
    cdl = PRE_CDL, lut_ref = nil, fidelity = "primary",
    reproduction = "full", source = "resolve", stale = 0, synced_at = now,
}, db)
local pre_grade_fp = ClipGrade.fingerprint(ClipGrade.load("c1", db))

-- Seed ledger link with pre_grade_fp already stamped (simulates a prior sync).
identity_ledger.upsert("c1", {
    resolve_item_id   = "live-r1",
    grade_fingerprint = pre_grade_fp,
    edit_fingerprint  = "edit-fp-before",
}, db)

-- ── apply: deliver a different grade ────────────────────────────────
local POST_CDL = {
    slope_r = 1.3, slope_g = 1.2, slope_b = 0.8,
    offset_r = -0.05, offset_g = 0.03, offset_b = 0.01,
    power_r  = 1.1, power_g = 0.9, power_b = 1.05,
    saturation = 0.75,
}
local to_wire = require("synthetic.helpers.grade_wire").cdl_model_to_wire
local response = {
    grades = {
        { resolve_item_id = "live-r1", cdl = to_wire(POST_CDL),
          fidelity = "primary", lut = nil },
    },
    warnings = {},
}
local captured = sync_grades.apply(response, "s", db, now + 60)

-- Ledger fingerprint must have changed to reflect the new grade.
local post_link = identity_ledger.load("c1", db)
local post_grade = ClipGrade.load("c1", db)
local post_grade_fp = post_grade and ClipGrade.fingerprint(post_grade)
check("ledger grade_fingerprint updated after apply",
    post_link and post_link.grade_fingerprint == post_grade_fp)
check("post-apply fingerprint differs from pre-apply fingerprint",
    post_link and post_link.grade_fingerprint ~= pre_grade_fp)

-- ── restore (undo) ───────────────────────────────────────────────────
sync_grades.restore(captured, db)

-- The key regression check: ledger fingerprint must revert to pre_grade_fp.
-- Without the fix, restore() only reverts clip_grade rows, leaving the
-- ledger with the post-apply fingerprint. The next SyncGrades would then
-- classify the reverted grade as "Resolve-only" drift and re-apply it.
local reverted_link = identity_ledger.load("c1", db)
check("restore reverts ledger grade_fingerprint to pre-apply value",
    reverted_link and reverted_link.grade_fingerprint == pre_grade_fp)
check("restore preserves ledger resolve_item_id",
    reverted_link and reverted_link.resolve_item_id == "live-r1")
check("restore preserves ledger edit_fingerprint",
    reverted_link and reverted_link.edit_fingerprint == "edit-fp-before")

-- The grade itself must also be reverted (existing behavior).
local reverted_grade = ClipGrade.load("c1", db)
check("restore reverts grade slope_r to pre-apply value",
    reverted_grade and reverted_grade.cdl
        and reverted_grade.cdl.slope_r == PRE_CDL.slope_r)

assert(fail == 0, "test_sync_grades_undo_reverts_ledger_fp.lua: failures present")
print("✅ test_sync_grades_undo_reverts_ledger_fp.lua passed")
