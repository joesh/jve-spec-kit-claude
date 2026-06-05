-- Piece 3 end-to-end smoke (run via `jve --test`).
--
-- Exercises the full FR-016 display path with real C++ bindings:
--
--   ClipGrade row (fidelity=partial, lut_ref=<.cube path>)
--     → view_grade_pull.pull_for_clip(clip_id)        → {lut_ref=...}
--     → EMP.SURFACE_SET_GRADE(nil) + SURFACE_SET_LUT3D(path)
--     → CPUVideoSurface.setLut3D                       → m_lut populated
--     → EMP.SURFACE_LUT3D_SIZE(surface)                → 33
--
-- Then walks every closed-set fidelity transition the pull layer
-- routes and asserts the surface state matches the spec rule:
--
--   primary + cdl        → CDL stage on, LUT off
--   primary + cdl + lut  → CDL on, LUT on (FR-016 stacking)
--   partial + lut        → CDL off, LUT on
--   unrepresentable+lut  → CDL off, LUT on
--   partial without lut  → both off (bake failed; badge UX only)
--   none / no row        → both off
--
-- Plus a couple of error-surface assertions on the binding itself
-- (bad path → luaL_error, not silent fallback — rule 2.32).

require("test_env")

local database        = require("core.database")
local view_grade_pull = require("core.view_grade_pull")
local ClipGrade       = require("models.clip_grade")

assert(qt_constants and qt_constants.EMP and qt_constants.WIDGET,
    "qt_constants.EMP/WIDGET unavailable — must run under `jve --test`")
local EMP    = qt_constants.EMP
local WIDGET = qt_constants.WIDGET
assert(EMP.SURFACE_SET_LUT3D,
    "EMP.SURFACE_SET_LUT3D missing — Piece 3.4 binding not registered")
assert(EMP.SURFACE_LUT3D_SIZE,
    "EMP.SURFACE_LUT3D_SIZE missing — getter not registered")
assert(EMP.SURFACE_SET_GRADE,
    "EMP.SURFACE_SET_GRADE missing")
assert(WIDGET.CREATE_CPU_VIDEO_SURFACE,
    "WIDGET.CREATE_CPU_VIDEO_SURFACE missing")

local pass, fail = 0, 0
local function ok(label, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1
         print(string.format("FAIL: %s%s", label,
             detail and (" — " .. tostring(detail)) or "")) end
end

print("\n=== Piece 3 end-to-end (view_grade_pull → surface) ===")

-- ── Test fixture: identity .cube on disk ────────────────────────────
-- Identity LUT size 33 (matches Resolve's 33PTCUBE bake). Output value
-- exactly equals input at every grid sample, so applying it is a
-- no-op for pixel output — but it lets us assert the upload landed
-- via SURFACE_LUT3D_SIZE.
local CUBE_PATH = "/tmp/jve/test_piece3_identity33.cube"
local CUBE_SIZE = 33
os.execute("mkdir -p /tmp/jve")
do
    local f = assert(io.open(CUBE_PATH, "w"))
    f:write("LUT_3D_SIZE " .. CUBE_SIZE .. "\n")
    for bi = 0, CUBE_SIZE - 1 do
        for gi = 0, CUBE_SIZE - 1 do
            for ri = 0, CUBE_SIZE - 1 do
                f:write(string.format("%.6f %.6f %.6f\n",
                    ri / (CUBE_SIZE - 1),
                    gi / (CUBE_SIZE - 1),
                    bi / (CUBE_SIZE - 1)))
            end
        end
    end
    f:close()
end

-- ── DB seed: one project, one seq, one track, one clip per fidelity case
local db_path = "/tmp/jve/test_piece3_lut3d_surface_pull.db"
os.remove(db_path)
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
    VALUES ('s', 'p', 'S', 'sequence', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id,
        sequence_id, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, source_in_subframe,
        source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id,
        fps_mismatch_policy, volume, playhead_frame)
    VALUES
        ('c_partial', 'p', 'cp', 't', 's', 's', 0,   96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_primary', 'p', 'cd', 't', 's', 's', 96,  96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_prim_lut','p', 'cl', 't', 's', 's', 192, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_unrepr',  'p', 'cu', 't', 's', 's', 288, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_part_no', 'p', 'cn', 't', 's', 's', 384, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_none',    'p', 'co', 't', 's', 's', 480, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
        ('c_nograde', 'p', 'ng', 't', 's', 's', 576, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now,
    now, now,  now, now,  now, now,  now, now,
    now, now,  now, now,  now, now))

local CDL = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r  = 1.1,  power_g  = 1.0, power_b  = 0.95,
    saturation = 0.85,
}

ClipGrade.upsert("c_partial",
    { cdl = nil, lut_ref = CUBE_PATH, fidelity = "partial",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
ClipGrade.upsert("c_primary",
    { cdl = CDL, lut_ref = nil, fidelity = "primary",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
ClipGrade.upsert("c_prim_lut",
    { cdl = CDL, lut_ref = CUBE_PATH, fidelity = "primary",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
ClipGrade.upsert("c_unrepr",
    { cdl = nil, lut_ref = CUBE_PATH, fidelity = "unrepresentable",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
ClipGrade.upsert("c_part_no",
    { cdl = nil, lut_ref = nil, fidelity = "partial",
      source = "resolve_readback", stale = 0, synced_at = now }, db)
-- c_none: no row (model treats absence as ungraded — FR-014).
-- c_nograde: no row either; the two are equivalent at the pull layer
-- but kept distinct so a future spec-013a check can target one.

-- ── Surface ─────────────────────────────────────────────────────────
local surface = WIDGET.CREATE_CPU_VIDEO_SURFACE()
assert(surface, "CREATE_CPU_VIDEO_SURFACE returned nil")
ok("baseline: surface starts with no LUT loaded",
    EMP.SURFACE_LUT3D_SIZE(surface) == 0,
    "size=" .. tostring(EMP.SURFACE_LUT3D_SIZE(surface)))

-- ── Helper: pull stages for clip_id, push to surface, return size ───
-- Mirrors SequenceMonitor._apply_clip_grade exactly so the test
-- validates the same code path the viewer uses.
local function apply_clip_grade_to_surface(clip_id)
    local stages = view_grade_pull.pull_for_clip(clip_id, db)
    local cdl     = stages and stages.cdl     or nil
    local lut_ref = stages and stages.lut_ref or nil
    EMP.SURFACE_SET_GRADE(surface, cdl)
    EMP.SURFACE_SET_LUT3D(surface, lut_ref)
    return stages, EMP.SURFACE_LUT3D_SIZE(surface)
end

-- ── Case: partial + lut → LUT stage active ──────────────────────────
do
    local stages, sz = apply_clip_grade_to_surface("c_partial")
    ok("partial+lut: stages returned",  stages ~= nil)
    ok("partial+lut: stages.cdl nil",   stages and stages.cdl == nil)
    ok("partial+lut: stages.lut_ref set",
        stages and stages.lut_ref == CUBE_PATH)
    ok("partial+lut: surface reports LUT size 33", sz == CUBE_SIZE,
        "got size=" .. tostring(sz))
end

-- ── Case: primary + cdl (no lut) → LUT cleared ──────────────────────
do
    local stages, sz = apply_clip_grade_to_surface("c_primary")
    ok("primary: stages returned",      stages ~= nil)
    ok("primary: CDL set",
        stages and stages.cdl and stages.cdl.slope_r == 1.05)
    ok("primary: lut_ref nil",          stages and stages.lut_ref == nil)
    ok("primary: surface LUT size 0 (cleared)", sz == 0,
        "got size=" .. tostring(sz))
end

-- ── Case: primary + cdl + lut → BOTH stages active (FR-016 stacking)─
do
    local stages, sz = apply_clip_grade_to_surface("c_prim_lut")
    ok("primary+lut: stages returned",  stages ~= nil)
    ok("primary+lut: CDL set",
        stages and stages.cdl and stages.cdl.slope_r == 1.05)
    ok("primary+lut: lut_ref set",
        stages and stages.lut_ref == CUBE_PATH)
    ok("primary+lut: surface LUT size 33", sz == CUBE_SIZE,
        "got size=" .. tostring(sz))
end

-- ── Case: unrepresentable + lut → LUT stage active ──────────────────
do
    local stages, sz = apply_clip_grade_to_surface("c_unrepr")
    ok("unrepresentable+lut: lut_ref forwarded",
        stages and stages.lut_ref == CUBE_PATH)
    ok("unrepresentable+lut: surface LUT size 33", sz == CUBE_SIZE)
end

-- ── Case: partial WITHOUT lut → both cleared (bake failed) ──────────
do
    local stages, sz = apply_clip_grade_to_surface("c_part_no")
    ok("partial-no-lut: stages nil", stages == nil)
    ok("partial-no-lut: surface LUT size 0", sz == 0)
end

-- ── Case: no clip_grade row → both cleared ──────────────────────────
do
    local stages, sz = apply_clip_grade_to_surface("c_nograde")
    ok("no-row: stages nil",      stages == nil)
    ok("no-row: surface LUT size 0", sz == 0)
end

-- ── Bad-path error surfacing (rule 2.32) ────────────────────────────
do
    local okcall, err = pcall(function()
        EMP.SURFACE_SET_LUT3D(surface, "/tmp/jve/does_not_exist.cube")
    end)
    ok("bad path → binding raises",
        (not okcall) and type(err) == "string"
        and err:find("SURFACE_SET_LUT3D") ~= nil,
        "err=" .. tostring(err))
end

do
    -- Write a malformed .cube; parse should refuse and bubble up.
    local bad = "/tmp/jve/test_piece3_malformed.cube"
    local f = assert(io.open(bad, "w"))
    f:write("LUT_3D_SIZE 4\n")
    f:write("0 0 0\n")  -- only one sample, not 64
    f:close()
    local okcall, err = pcall(function()
        EMP.SURFACE_SET_LUT3D(surface, bad)
    end)
    ok("malformed .cube → binding raises",
        (not okcall) and type(err) == "string"
        and err:find("truncated") ~= nil,
        "err=" .. tostring(err))
end

-- ── Transition stress: alternating sets should always settle to the
-- last-set state. Verifies setLut3D's texture-reuse path doesn't
-- carry over stale enable flags when the same path is set repeatedly.
do
    EMP.SURFACE_SET_LUT3D(surface, CUBE_PATH)
    ok("transition: set → size 33", EMP.SURFACE_LUT3D_SIZE(surface) == CUBE_SIZE)
    EMP.SURFACE_SET_LUT3D(surface, nil)
    ok("transition: nil → size 0",  EMP.SURFACE_LUT3D_SIZE(surface) == 0)
    EMP.SURFACE_SET_LUT3D(surface, CUBE_PATH)
    ok("transition: re-set → size 33 again", EMP.SURFACE_LUT3D_SIZE(surface) == CUBE_SIZE)
end

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_piece3_lut3d_surface_pull.lua: failures present")
print("✅ test_piece3_lut3d_surface_pull.lua passed")
