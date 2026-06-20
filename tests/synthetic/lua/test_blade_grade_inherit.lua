-- Spec 023 FR-012 — blading a graded clip must not change what the
-- viewer sees: BOTH halves carry the parent's grade, an unrelated
-- graded clip is untouched (no scrambling), undo restores the single
-- graded clip (the right half's grade row goes with the right half),
-- and blading an UNGRADED clip mints no grade rows.
--
-- Domain rationale: a blade is a timeline edit; rendered output is
-- invariant across it. The View pulls grades by clip id
-- (view_grade_pull), and the right half is a new clip id — so the
-- grade must travel with the split, not be re-derived later.
--
-- Black-box: DB state via ClipGrade.load only; expected values are the
-- data-model.md non-trivial CDL, never read back from the code.

require("test_env")
local database = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")
local ClipGrade = require("models.clip_grade")
local command_manager = require("core.command_manager")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== blade grade inherit Tests ===")

local DB_PATH = "/tmp/jve/test_blade_grade_inherit.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql init failed")
local db = database.get_connection()
db:exec(require("import_schema"))

Project.create("p", {
    id = "p1",
    fps_mismatch_policy = "passthrough",
    settings = {
        master_clock_hz = 192000,
        default_fps = { num = 24, den = 1 },
    },
}):save()
Sequence.create("m", "p1", { fps_numerator = 24, fps_denominator = 1 },
    1920, 1080, { id = "m", kind = "master" }):save()
Sequence.create("edit", "p1", { fps_numerator = 24, fps_denominator = 1 },
    1920, 1080, { id = "e", kind = "sequence",
                  audio_sample_rate = 48000 }):save()
Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
Track.create_video("V1", "e", { id = "e-v1", index = 1 }):save()
db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")
Media.create({
    id = "med-v", project_id = "p1", name = "v.mov",
    file_path = "/tmp/v.mov", duration_frames = 2000,
    fps_numerator = 24, fps_denominator = 1, audio_channels = 0,
    metadata = '{"start_tc_value":0,"start_tc_rate":24}',
}):save()
db:exec([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames, audio_sample_rate,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 2000, 0, 2000, 48000,
        1, 1.0, 0, 0, 0);
]])
command_manager.init("e", "p1")

local function seed_clip(clip_id, sequence_start, duration, source_in)
    local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
    assert(Clip.create({
        id = clip_id, project_id = "p1", owner_sequence_id = "e",
        track_id = "e-v1", sequence_id = "m", name = clip_id,
        sequence_start_frame = sequence_start, duration_frames = duration,
        source_in_frame = source_in,
        source_out_frame = source_in + duration,
        source_in_subframe = sub_in, source_out_subframe = sub_out,
        master_layer_track_id = nil, fps_mismatch_policy = "passthrough",
        enabled = true, volume = 1.0, playhead_frame = 0,
    }) == clip_id, "seed_clip failed: " .. clip_id)
end

-- data-model.md §non-trivial test values
local PARENT_CDL = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r = 1.1, power_g = 1.0, power_b = 0.95,
    saturation = 0.85,
}
local OTHER_CDL = {
    slope_r = 0.90, slope_g = 1.00, slope_b = 1.10,
    offset_r = 0.05, offset_g = 0.04, offset_b = 0.03,
    power_r = 1.20, power_g = 1.10, power_b = 1.00,
    saturation = 1.10,
}

seed_clip("parent", 100, 200, 0)
seed_clip("other",  400, 100, 500)
ClipGrade.upsert("parent", { cdl = PARENT_CDL, lut_ref = nil,
    fidelity = "primary", reproduction = "full", source = "resolve", stale = 0,
    synced_at = 1770000000 }, db)
ClipGrade.upsert("other", { cdl = OTHER_CDL, lut_ref = nil,
    fidelity = "primary", reproduction = "full", source = "resolve", stale = 0,
    synced_at = 1770000000 }, db)

local function cdl_equal(a, b)
    if not a or not b then return false end
    for _, ch in ipairs({ "slope_r", "slope_g", "slope_b",
                          "offset_r", "offset_g", "offset_b",
                          "power_r", "power_g", "power_b",
                          "saturation" }) do
        if a[ch] ~= b[ch] then return false end
    end
    return true
end

local function right_half_id()
    local rows = database.select_rows(db,
        "SELECT id FROM clips WHERE track_id = 'e-v1' "
        .. "AND id NOT IN ('parent', 'other', 'plain') "
        .. "ORDER BY sequence_start_frame",
        {}, function(stmt) return stmt:value(0) end)
    return rows[1]
end

-- ─── blade the graded clip ───────────────────────────────────────────
local exec = command_manager.execute("SplitClip", {
    project_id = "p1", sequence_id = "e",
    clip_id = "parent", split_frame = 160,
})
assert(exec and exec.success ~= false,
    "SplitClip execute failed: " .. tostring(exec and exec.error_message))
local right = right_half_id()
check("split produced a right half", right ~= nil)

local g_left  = ClipGrade.load("parent", db)
local g_right = right and ClipGrade.load(right, db) or nil
check("left half keeps the parent grade",
    g_left and cdl_equal(g_left.cdl, PARENT_CDL))
check("right half inherits the parent grade (FR-012 both-inherit)",
    g_right and cdl_equal(g_right.cdl, PARENT_CDL))
check("right half inherits grade metadata",
    g_right and g_right.fidelity == "primary"
    and g_right.source == "resolve" and g_right.stale == 0
    and g_right.synced_at == 1770000000)
local g_other = ClipGrade.load("other", db)
check("unrelated clip's grade is not scrambled",
    g_other and cdl_equal(g_other.cdl, OTHER_CDL))

-- ─── undo: single graded clip again, no orphan grade row ────────────
assert(command_manager.undo(), "undo failed")
check("undo removes the right half's grade with the right half",
    ClipGrade.load(right, db) == nil)
check("undo keeps the parent grade",
    cdl_equal(ClipGrade.load("parent", db).cdl, PARENT_CDL))
local count_after_undo = database.select_rows(db,
    "SELECT COUNT(*) FROM clip_grade", {},
    function(stmt) return stmt:value(0) end)[1]
check("exactly the two seeded grade rows remain after undo",
    count_after_undo == 2)

-- ─── redo: both halves graded again ─────────────────────────────────
assert(command_manager.redo(), "redo failed")
local right2 = right_half_id()
check("redo restores the right half", right2 ~= nil)
check("redo restores the inherited grade",
    right2 and cdl_equal(ClipGrade.load(right2, db).cdl, PARENT_CDL))

-- ─── blading an ungraded clip mints no grade rows ───────────────────
seed_clip("plain", 600, 100, 900)
assert(command_manager.execute("SplitClip", {
    project_id = "p1", sequence_id = "e",
    clip_id = "plain", split_frame = 650,
}), "SplitClip on ungraded clip failed")
local total = database.select_rows(db,
    "SELECT COUNT(*) FROM clip_grade", {},
    function(stmt) return stmt:value(0) end)[1]
check("ungraded blade mints no grade rows", total == 3)

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_blade_grade_inherit.lua had failures")
print("✅ test_blade_grade_inherit.lua passed")
