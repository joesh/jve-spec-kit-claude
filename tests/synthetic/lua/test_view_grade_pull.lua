-- test_view_grade_pull.lua — black-box: the View's MVC pull rule for
-- per-clip CDL display (T032 / FR-016).
--
-- Domain rule (FR-016, spec.md / quickstart scenario 2-3):
--   The viewer displays the stored PRIMARY grade by applying CDL.
--   A grade marked 'partial' or 'unrepresentable' MUST NOT be applied
--   — the viewer instead shows the ungraded image and (per spec §5.5)
--   surfaces a fidelity badge. A clip with no grade row displays
--   ungraded. A 'primary'-fidelity grade with stale=1 keeps applying
--   the last-known values (FR-013a: "retained, marked stale, never
--   silently cleared").
--
-- This test pins the rule of the pull module the View calls every time
-- it shows a frame: given a clip_id and the DB, the module returns
-- either the CDL params (RGB triples + sat) to apply, or nil meaning
-- "passthrough".

require("test_env")

local database = require("core.database")
local ClipGrade = require("models.clip_grade")
local view_grade_pull = require("core.view_grade_pull")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== View Grade Pull Tests ===")

local db_path = "/tmp/jve/test_view_grade_pull.db"
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
    VALUES
        ('c_primary',  'p', 'c_primary',  't', 's', 's', 0,   96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_partial',  'p', 'c_partial',  't', 's', 's', 96,  96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_unrepr',   'p', 'c_unrepr',   't', 's', 's', 192, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_nograde',  'p', 'c_nograde',  't', 's', 's', 288, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_stale_p',  'p', 'c_stale_p',  't', 's', 's', 384, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_unrepr_with_lut',  'p', 'c_uwl',  't', 's', 's', 480, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_primary_with_lut', 'p', 'c_pwl',  't', 's', 's', 576, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now,
    now, now,  now, now,  now, now,  now, now,  now, now,
    now, now,  now, now))

local CDL = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r  = 1.1,  power_g  = 1.0, power_b  = 0.95,
    saturation = 0.85,
}

-- Seed: a primary grade, a partial-with-LUT grade, an unrepresentable
-- grade, no grade, and a stale-primary grade.
ClipGrade.upsert("c_primary",
    { cdl = CDL, lut_ref = nil, fidelity = "primary",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
ClipGrade.upsert("c_partial",
    { cdl = nil, lut_ref = "/tmp/jve/grade.cube", fidelity = "partial",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
ClipGrade.upsert("c_unrepr",
    { cdl = nil, lut_ref = nil, fidelity = "unrepresentable",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
ClipGrade.upsert("c_stale_p",
    { cdl = CDL, lut_ref = nil, fidelity = "primary",
      source = "resolve_readback", stale = 1, synced_at = now }, db)

-- ─── primary grade returns {cdl=...} stage table ─────────────────────
do
    local stages = view_grade_pull.pull_for_clip("c_primary", db)
    check("primary returns stage table",
        type(stages) == "table" and type(stages.cdl) == "table")
    check("primary has no LUT (c_primary seeded with lut_ref=nil)",
        stages and stages.lut_ref == nil)
    check("slope_r forwards",      stages.cdl and stages.cdl.slope_r == 1.05)
    check("offset_b forwards",     stages.cdl and stages.cdl.offset_b == -0.02)
    check("saturation forwards",   stages.cdl and stages.cdl.saturation == 0.85)
end

-- ─── partial + lut_ref → display the bake (Piece 3 / FR-015) ─────────
do
    local stages = view_grade_pull.pull_for_clip("c_partial", db)
    check("partial returns stage table",
        type(stages) == "table")
    check("partial has lut_ref",
        stages and stages.lut_ref == "/tmp/jve/grade.cube")
    check("partial has no CDL",
        stages and stages.cdl == nil)
end

-- ─── unrepresentable WITHOUT lut_ref → nil (bake failed) ─────────────
-- Seed (line 83) sets c_unrepr with lut_ref=nil; the fidelity badge
-- alone tells the user the grade exists but couldn't load.
do
    local stages = view_grade_pull.pull_for_clip("c_unrepr", db)
    check("unrepresentable without lut → nil", stages == nil)
end

-- ─── clip without a grade row → nil ──────────────────────────────────
do
    local stages = view_grade_pull.pull_for_clip("c_nograde", db)
    check("no grade row → nil", stages == nil)
end

-- ─── stale=1 primary still applies (FR-013a) ─────────────────────────
do
    local stages = view_grade_pull.pull_for_clip("c_stale_p", db)
    check("stale primary still applies (FR-013a)",
        type(stages) == "table" and type(stages.cdl) == "table")
    check("stale primary slope_g forwards",
        stages and stages.cdl and stages.cdl.slope_g == 0.98)
end

-- ─── unrepresentable WITH lut_ref → display the bake (Piece 3) ───────
-- Same FR-015 rule as partial: the bake captures primaries + curves +
-- CST/ACES; if it was emitted at all, display it (badge communicates
-- the lossiness).
ClipGrade.upsert("c_unrepr_with_lut",
    { cdl = nil, lut_ref = "/tmp/jve/unrepr.cube",
      fidelity = "unrepresentable",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
do
    local stages = view_grade_pull.pull_for_clip("c_unrepr_with_lut", db)
    check("unrepresentable + lut → stage table",
        type(stages) == "table")
    check("unrepresentable + lut → lut_ref forwards",
        stages and stages.lut_ref == "/tmp/jve/unrepr.cube")
    check("unrepresentable + lut → no CDL",
        stages and stages.cdl == nil)
end

-- ─── primary + item-LUT → BOTH stages forwarded (FR-016 stacking) ────
-- Rare case: user had an item-level LUT bound to a primary-only graph.
ClipGrade.upsert("c_primary_with_lut",
    { cdl = CDL, lut_ref = "/tmp/jve/itemlut.cube", fidelity = "primary",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
do
    local stages = view_grade_pull.pull_for_clip("c_primary_with_lut", db)
    check("primary + lut → stage table",
        type(stages) == "table")
    check("primary + lut → CDL forwards",
        stages and type(stages.cdl) == "table"
        and stages.cdl.slope_r == 1.05)
    check("primary + lut → LUT forwards",
        stages and stages.lut_ref == "/tmp/jve/itemlut.cube")
end

-- ─── nil/empty clip_id is a caller bug, not a passthrough ────────────
-- The "gap frame → no grade" rule lives in the render path
-- (SequenceMonitor:_clear_clip_grade), not here. Passing nil into the
-- model layer would silently swallow misrouted callers — rule 2.13.
do
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
    expect_assert("nil clip_id asserts", function()
        view_grade_pull.pull_for_clip(nil, db)
    end, "non-empty")
    expect_assert("empty clip_id asserts", function()
        view_grade_pull.pull_for_clip("", db)
    end, "non-empty")
end

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, string.format("%d test(s) failed", fail))

print("✅ test_view_grade_pull.lua passed")
