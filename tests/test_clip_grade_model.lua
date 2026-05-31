-- test_clip_grade_model.lua — black-box `models.clip_grade` contract.
--
-- Domain (per data-model.md):
--   • A grade is per-clip (PK clip_id, FK clips ON DELETE CASCADE).
--   • CDL is all-nine-or-none: either all 9 channels + saturation are
--     present (representable primary), or all NULL (non-primary).
--     Writing a partial CDL is a programming bug and must assert.
--   • fidelity is one of 'primary' / 'partial' / 'unrepresentable';
--     anything else asserts.
--   • Deleting the owning clip cascades the grade row (FR-013a).
--   • Marking the source Resolve item missing sets stale=1; the grade
--     VALUES are retained (FR-014).
--
-- Expected values come from data-model.md "Non-trivial test values":
--   slope  (1.05, 0.98, 0.92)
--   offset (0.01, 0.0, -0.02)
--   power  (1.1, 1.0, 0.95)
--   sat    0.85
-- Not 1.0 identity — those hide bugs (test_quality / 2.32).

require("test_env")

local database = require("core.database")
local ClipGrade = require("models.clip_grade")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end
local function expect_assert(label, fn, substr)
    local ok, err = pcall(fn)
    if ok then
        fail = fail + 1
        print("FAIL (expected assert): " .. label)
        return
    end
    if substr and not tostring(err):find(substr, 1, true) then
        fail = fail + 1
        print(string.format("FAIL (msg %q lacks %q): %s",
            tostring(err), substr, label))
        return
    end
    pass = pass + 1
end

print("\n=== ClipGrade Model Tests ===")

local db_path = "/tmp/jve/test_clip_grade_model.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'resample',
        '{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24000, 1001, 48000, 1920, 1080, 0, 240, 0,
        '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume,
        playhead_frame)
    VALUES ('c1', 'p', 'c1', 't', 's', 's', 0, 96, 0, 96, NULL, NULL, 1, %d, %d,
        NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now))

-- ─── round-trip a primary-fidelity grade ─────────────────────────────
local CDL = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r  = 1.1,  power_g  = 1.0, power_b  = 0.95,
    saturation = 0.85,
}
ClipGrade.upsert("c1", {
    cdl = CDL,
    lut_ref = nil,
    fidelity = "primary",
    source = "resolve_readback",
    stale = 0,
    synced_at = now,
}, db)

local g = ClipGrade.load("c1", db)
check("loaded grade exists",            g ~= nil)
check("slope_r round-trips",            g and g.cdl and g.cdl.slope_r == 1.05)
check("offset_b (-0.02) round-trips",   g and g.cdl and g.cdl.offset_b == -0.02)
check("power_g (unity) round-trips",    g and g.cdl and g.cdl.power_g == 1.0)
check("saturation round-trips",         g and g.cdl and g.cdl.saturation == 0.85)
check("fidelity round-trips",           g and g.fidelity == "primary")
check("source round-trips",             g and g.source == "resolve_readback")
check("stale=0 round-trips",            g and g.stale == 0)

-- ─── partial-fidelity grade with LUT only (CDL = nil) ────────────────
ClipGrade.upsert("c1", {
    cdl = nil,
    lut_ref = "/tmp/jve/grade.cube",
    fidelity = "partial",
    source = "resolve_readback",
    stale = 0,
    synced_at = now,
}, db)
local g2 = ClipGrade.load("c1", db)
check("partial-fidelity has no CDL",    g2 and g2.cdl == nil)
check("partial-fidelity LUT survives",  g2 and g2.lut_ref == "/tmp/jve/grade.cube")
check("fidelity flips to 'partial'",    g2 and g2.fidelity == "partial")

-- ─── fail-fast on partial CDL (8-of-9 set, power_b NULL) ─────────────
expect_assert("partial CDL rejected at boundary", function()
    local partial = {}
    for k, v in pairs(CDL) do partial[k] = v end
    partial.power_b = nil
    ClipGrade.upsert("c1", {
        cdl = partial,
        lut_ref = nil,
        fidelity = "primary",
        source = "resolve_readback",
        stale = 0,
        synced_at = now,
    }, db)
end, "power_b")

-- ─── fail-fast on bad fidelity enum ──────────────────────────────────
expect_assert("bad fidelity value rejected", function()
    ClipGrade.upsert("c1", {
        cdl = CDL,
        lut_ref = nil,
        fidelity = "deluxe",  -- not in the enum
        source = "resolve_readback",
        stale = 0,
        synced_at = now,
    }, db)
end, "fidelity")

-- ─── stale=1 retains the grade values (FR-014) ───────────────────────
ClipGrade.upsert("c1", {
    cdl = CDL,
    lut_ref = nil,
    fidelity = "primary",
    source = "resolve_readback",
    stale = 1,
    synced_at = now,
}, db)
local g3 = ClipGrade.load("c1", db)
check("stale=1 keeps slope values",     g3 and g3.cdl and g3.cdl.slope_r == 1.05)
check("stale=1 stored",                 g3 and g3.stale == 1)

-- ─── delete clip cascades grade row (FR-013a) ────────────────────────
db:exec("DELETE FROM clips WHERE id = 'c1';")
local g4 = ClipGrade.load("c1", db)
check("grade gone after clip delete (cascade)", g4 == nil)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_clip_grade_model.lua: failures present")
print("✅ test_clip_grade_model.lua passed")
