-- spec 023 regression — apply must consume the helper-protocol §read_grades
-- WIRE shape (slope:[r,g,b], offset:[r,g,b], power:[r,g,b], sat: float),
-- NOT the JVE clip_grade model shape (slope_r, slope_g, ..., saturation).
-- The earlier tests fed apply model-shape data, masking the wire/model
-- boundary translation gap. Reaching this gap in production was the
-- "bad argument #3 to 'format' (number expected, got nil)" crash in
-- ClipGrade.fingerprint when the helper actually sent a primary CDL.

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

print("\n=== SyncGradesFromResolve wire-shape Tests ===")

local db_path = "/tmp/jve/test_sync_grades_wire_shape.db"
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
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('s','p','S','sequence',24000,1001,48000,1920,1080,
        0,240,0,'[]','[]',%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t','s','V1','VIDEO',1,1,0,0,0,1.0,0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
        volume, playhead_frame)
    VALUES ('c','p','C','t','s','s',0,96,0,96,NULL,NULL,
        1,%d,%d,NULL,NULL,'resample',1.0,0);
]], now, now, now, now, now, now))

identity_ledger.upsert("c", { resolve_item_id = "live_c" }, db)

-- Helper wire shape per contracts/helper-protocol.md §read_grades:
--   { grades: [{ resolve_item_id,
--                cdl?: { slope:[r,g,b], offset:[r,g,b], power:[r,g,b], sat },
--                lut?: { ref },
--                fidelity }] }
-- Non-identity, distinguishable per channel so any wire-vs-model bug
-- surfaces as a wrong value, not an accidental pass.
local response = {
    grades = {
        {
            resolve_item_id = "live_c",
            fidelity        = "primary",
            cdl = {
                slope  = {1.05, 0.98, 0.92},
                offset = {0.01, 0.0,  -0.02},
                power  = {1.10, 1.0,  0.95},
                sat    = 0.85,
            },
        },
    },
}

local captured = sync_grades.apply(response, "s", db, now + 60)

local g = ClipGrade.load("c", db)
check("primary grade row was created", g ~= nil and g.cdl ~= nil)
check("slope_r picked up from wire slope[1]",
    g and g.cdl and g.cdl.slope_r == 1.05)
check("slope_g picked up from wire slope[2]",
    g and g.cdl and g.cdl.slope_g == 0.98)
check("slope_b picked up from wire slope[3]",
    g and g.cdl and g.cdl.slope_b == 0.92)
check("offset_r picked up from wire offset[1]",
    g and g.cdl and g.cdl.offset_r == 0.01)
check("offset_g picked up from wire offset[2]",
    g and g.cdl and g.cdl.offset_g == 0.0)
check("offset_b picked up from wire offset[3]",
    g and g.cdl and g.cdl.offset_b == -0.02)
check("power_r picked up from wire power[1]",
    g and g.cdl and g.cdl.power_r == 1.10)
check("power_g picked up from wire power[2]",
    g and g.cdl and g.cdl.power_g == 1.0)
check("power_b picked up from wire power[3]",
    g and g.cdl and g.cdl.power_b == 0.95)
check("saturation picked up from wire sat",
    g and g.cdl and g.cdl.saturation == 0.85)

-- Restore unwinds cleanly.
sync_grades.restore(captured, db)
check("restore drops the synced row (clip had no prior grade)",
    ClipGrade.load("c", db) == nil)

-- lut wire validation: bad shapes must warn + skip, never crash.
-- State at this point: restore dropped the synced row, so no grade exists.
do
    -- lut as a non-table (string) → validate_grade_wire_item rejects it
    local ok, _ = pcall(sync_grades.apply,
        { grades = {{ resolve_item_id = "live_c",
                      fidelity = "partial",
                      lut = "not_a_table" }} },
        "s", db, now + 120)
    check("lut as string does not crash apply", ok == true)
    check("lut-as-string item is dropped (no grade created)",
        ClipGrade.load("c", db) == nil)

    -- lut as table with missing ref → validate_grade_wire_item rejects it
    local ok2, _ = pcall(sync_grades.apply,
        { grades = {{ resolve_item_id = "live_c",
                      fidelity = "partial",
                      lut = {} }} },
        "s", db, now + 123)
    check("lut table with no ref does not crash apply", ok2 == true)
    check("lut-no-ref item is dropped (no grade created)",
        ClipGrade.load("c", db) == nil)

    -- lut as table with empty ref → validate_grade_wire_item rejects it
    local ok3, _ = pcall(sync_grades.apply,
        { grades = {{ resolve_item_id = "live_c",
                      fidelity = "partial",
                      lut = { ref = "" } }} },
        "s", db, now + 126)
    check("lut with empty ref does not crash apply", ok3 == true)
    check("lut-empty-ref item is dropped (no grade created)",
        ClipGrade.load("c", db) == nil)

    -- valid lut → accepted, grade created with lut_ref
    local ok4, _ = pcall(sync_grades.apply,
        { grades = {{ resolve_item_id = "live_c",
                      fidelity = "partial",
                      lut = { ref = "/path/to/grade.cube" } }} },
        "s", db, now + 129)
    check("valid lut {ref} does not crash apply", ok4 == true)
    local g2 = ClipGrade.load("c", db)
    check("valid lut creates grade with lut_ref",
        g2 ~= nil and g2.lut_ref == "/path/to/grade.cube")
end

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_sync_grades_wire_shape.lua: failures present")
print("✅ test_sync_grades_wire_shape.lua passed")
