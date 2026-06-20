-- test_clip_grade_reproduction.lua — `reproduction` axis on clip_grade
-- (spec 023 FR-015 badge foundation).
--
-- Domain: `fidelity` says how complex the RESOLVE grade is; `reproduction`
-- says what JVE can actually DISPLAY of it. They are independent axes.
--   • full        — JVE reproduces the grade (primary CDL).
--   • approximate — non-primary, but a non-identity baked LUT shows part of it.
--   • not_shown   — grade exists but JVE renders passthrough: the baked LUT
--                   is identity (spatial grade — power window / sizing) OR
--                   there is no displayable carrier at all.
--
-- These expectations come from the user-visible contract (what the viewer
-- shows), not from tracing code: a clip whose only carrier bakes to a
-- passthrough must read as "not shown", never silently as graded (2.32).

require("test_env")

local database  = require("core.database")
local ClipGrade = require("models.clip_grade")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end
end
local function expect_assert(label, fn)
    local ok = pcall(fn)
    if ok then fail = fail + 1; print("FAIL (expected assert): " .. label)
    else pass = pass + 1 end
end

print("\n=== ClipGrade reproduction classification ===")

-- ── pure classifier ────────────────────────────────────────────────
local C = ClipGrade.classify_reproduction
check("primary → full",            C("primary", nil, nil) == "full")
check("primary + lut → full",      C("primary", "/x.cube", false) == "full")
check("partial + real lut → approximate",
    C("partial", "/x.cube", false) == "approximate")
check("unrepresentable + real lut → approximate",
    C("unrepresentable", "/x.cube", false) == "approximate")
check("unrepresentable + identity lut → not_shown",
    C("unrepresentable", "/x.cube", true) == "not_shown")
check("partial + identity lut → not_shown",
    C("partial", "/x.cube", true) == "not_shown")
check("non-primary + no lut → not_shown",
    C("unrepresentable", nil, nil) == "not_shown")
-- lut present but identity-ness unknown is a programming bug — assert.
expect_assert("lut without identity verdict asserts",
    function() return C("partial", "/x.cube", nil) end)
expect_assert("bad fidelity asserts",
    function() return C("bogus", nil, nil) end)

-- ── store / load round-trip ─────────────────────────────────────────
local db_path = "/tmp/jve/test_clip_grade_reproduction.db"
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

ClipGrade.upsert("c1", {
    cdl = nil, lut_ref = "/bake/c1.cube",
    fidelity = "unrepresentable", reproduction = "not_shown",
    source = "resolve", stale = 0, synced_at = now,
}, db)
local g = ClipGrade.load("c1", db)
check("reproduction round-trips", g and g.reproduction == "not_shown")

expect_assert("bad reproduction value asserts", function()
    ClipGrade.upsert("c1", {
        cdl = nil, lut_ref = nil, fidelity = "partial",
        reproduction = "bogus", source = "resolve", stale = 0, synced_at = now,
    }, db)
end)
expect_assert("missing reproduction asserts", function()
    ClipGrade.upsert("c1", {
        cdl = nil, lut_ref = nil, fidelity = "partial",
        source = "resolve", stale = 0, synced_at = now,
    }, db)
end)

-- ── batch reproduction load ─────────────────────────────────────────
-- c1 currently carries reproduction='not_shown' (the round-trip upsert
-- above; the later expect_assert upserts failed and left it unchanged).
local batch = ClipGrade.load_reproduction_batch({ "c1", "nonexistent" }, db)
check("batch returns reproduction for graded clip",
    batch.c1 == "not_shown")
check("batch omits clips with no grade row",
    batch.nonexistent == nil)
check("empty batch input → empty map",
    next(ClipGrade.load_reproduction_batch({}, db)) == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_clip_grade_reproduction.lua had failures")
print("✅ test_clip_grade_reproduction.lua passed")
