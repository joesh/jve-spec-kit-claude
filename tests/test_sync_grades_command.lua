-- T030 — SyncGradesFromResolve apply + undo (spec 023, FR-017).
--
-- Black-box: feed the command a synthetic helper response (the shape
-- helper-protocol.md defines for `read_grades`), assert clip_grade rows
-- match. Then restore the captured before-state and assert it reverts —
-- including that a clip that started UNGRADED has no grade row again
-- (data-model.md: undo restores prior state).
--
-- The test exercises apply()/restore() as pure-data functions; the full
-- command:execute() path is exercised by integration once T029 (helper
-- read_grades verb) is implemented. Same architectural rule as other
-- non-mocked tests: NO mocks — apply()/restore() take a literal grades
-- list (the shape the helper would deliver) and a db handle; the test
-- constructs the list directly.

require("test_env")

local database = require("core.database")
local ClipGrade = require("models.clip_grade")
local sync_grades = require("core.commands.sync_grades_from_resolve")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== SyncGradesFromResolve Tests ===")

local db_path = "/tmp/jve/test_sync_grades_command.db"
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
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('c_pre',  'p', 'pre',  't', 's', 's', 0,   96, 0, 96, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
           ('c_none', 'p', 'none', 't', 's', 's', 96, 96, 0, 96, NULL, NULL,
        1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now))

-- c_pre has a starting grade; c_none does not. Non-identity values so
-- the test cannot pass by accident (rule test_quality / 2.32).
local PRE_CDL = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r  = 1.1,  power_g  = 1.0, power_b  = 0.95,
    saturation = 0.85,
}
ClipGrade.upsert("c_pre", {
    cdl = PRE_CDL, lut_ref = nil, fidelity = "primary",
    source = "user", stale = 0, synced_at = now,
}, db)

-- ─── apply: a sync delivers fresh grades for both clips ─────────────
local POST_CDL_pre = {
    slope_r = 1.20, slope_g = 1.15, slope_b = 1.10,
    offset_r = -0.01, offset_g = -0.02, offset_b = -0.03,
    power_r  = 0.95,  power_g  = 1.05, power_b  = 1.00,
    saturation = 0.70,
}
local POST_CDL_none = {
    slope_r = 0.90, slope_g = 1.00, slope_b = 1.10,
    offset_r = 0.05, offset_g = 0.04, offset_b = 0.03,
    power_r  = 1.20,  power_g  = 1.10, power_b  = 1.00,
    saturation = 1.10,
}
local response = {
    grades = {
        { jve_guid = "c_pre",  cdl = POST_CDL_pre,
          fidelity = "primary", lut = nil },
        { jve_guid = "c_none", cdl = POST_CDL_none,
          fidelity = "primary", lut = nil },
    },
}
local captured = sync_grades.apply(response, db, now + 60)

local applied_pre = ClipGrade.load("c_pre", db)
check("c_pre post-apply slope_r is new value",
    applied_pre and applied_pre.cdl
        and applied_pre.cdl.slope_r == POST_CDL_pre.slope_r)
check("c_pre source recorded as 'resolve'",
    applied_pre and applied_pre.source == "resolve")
local applied_none = ClipGrade.load("c_none", db)
check("c_none post-apply has a grade row now",
    applied_none ~= nil)
check("c_none post-apply saturation is new value",
    applied_none and applied_none.cdl
        and applied_none.cdl.saturation == POST_CDL_none.saturation)

-- ─── restore: undo reverts to captured state ───────────────────────
sync_grades.restore(captured, db)
local restored_pre = ClipGrade.load("c_pre", db)
check("c_pre restored slope_r matches original",
    restored_pre and restored_pre.cdl
        and restored_pre.cdl.slope_r == PRE_CDL.slope_r)
check("c_pre restored source matches original",
    restored_pre and restored_pre.source == "user")
local restored_none = ClipGrade.load("c_none", db)
check("c_none restored has NO grade row (was ungraded before sync)",
    restored_none == nil)

-- ─── re-apply after restore yields the same captured state ─────────
-- Idempotency check: apply→restore→apply should land at the post-state.
local captured2 = sync_grades.apply(response, db, now + 120)
local reapplied_pre = ClipGrade.load("c_pre", db)
check("re-apply: c_pre slope_r is post-state again",
    reapplied_pre and reapplied_pre.cdl
        and reapplied_pre.cdl.slope_r == POST_CDL_pre.slope_r)
check("re-apply captured the post-restore state",
    captured2 ~= nil and #captured2.entries == 2)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_sync_grades_command.lua: failures present")
print("✅ test_sync_grades_command.lua passed")
