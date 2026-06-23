-- Regression: per-clip CDL grade must follow the clip during playback.
--
-- Invariant: after every clip-boundary transition — in either direction
-- — the surface's CDL slope MUST reflect the newly-active clip's grade,
-- not the previous clip's. Spec 023 FR-016.
--
-- Black-box: assign distinct CDLs to two clips, seek onto each, read the
-- live slope back from the surface, expect it to match the seek target's
-- grade.
--
-- Must run via: JVEEditor --test tests/synthetic/integration/test_playback_grade_clip_transition.lua

local ienv = require("synthetic.integration.integration_test_env")

print("=== test_playback_grade_clip_transition.lua ===")

local EMP = ienv.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
assert(PLAYBACK, "PLAYBACK bindings not available")
assert(PLAYBACK.SET_CLIP_GRADE,
    "PLAYBACK.SET_CLIP_GRADE missing — the per-clip grade snapshot binding "
    .. "must exist for playback to deliver per-clip CDL without a Lua "
    .. "roundtrip per frame.")
assert(EMP.SURFACE_GET_GRADE_SLOPE,
    "EMP.SURFACE_GET_GRADE_SLOPE missing — required to assert the live "
    .. "CDL uniform on the surface after a clip transition.")

local WIDGET = qt_constants.WIDGET
local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not surface then
    print("  SKIP: GPU surface creation failed (headless?)")
    print("✅ test_playback_grade_clip_transition.lua passed (skipped)")
    return
end

local failures = {}
local function expect(cond, msg)
    if cond then
        print("  PASS: " .. msg)
    else
        failures[#failures + 1] = msg
        print("  FAIL: " .. msg)
    end
end

local SEQ_FPS_NUM, SEQ_FPS_DEN = 25, 1
local FIXTURE_DIR = ienv.resolve_repo_path("tests/fixtures/media")
local FILES = {
    FIXTURE_DIR .. "/A005_C052_0925BL_001.mp4",
    FIXTURE_DIR .. "/A002_C018_0922BW_002.mp4",
}

local clips = {}
local sequence_start = 0
for i, path in ipairs(FILES) do
    local f = io.open(path, "r"); assert(f, "Missing fixture: " .. path); f:close()
    local info = EMP.MEDIA_FILE_PROBE(path)
    local origin = assert(info.first_frame_tc, "probe failed: " .. path)
    local secs = (info.duration_us or 0) / 1e6
    if secs <= 0 then secs = 1.0 end
    local frames = math.max(10, math.floor(secs * 25.0) - 2)
    clips[#clips + 1] = {
        clip_id = string.format("clip_%d", i),
        media_path = path,
        sequence_start = sequence_start,
        duration = frames,
        source_in = origin,
        rate_num = SEQ_FPS_NUM, rate_den = SEQ_FPS_DEN, speed_ratio = 1.0,
    }
    sequence_start = sequence_start + frames
end
local SEQ_HI = sequence_start

local tmb = EMP.TMB_CREATE(3)
EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, clips)

local pc = PLAYBACK.CREATE()
PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, 0, SEQ_HI, SEQ_FPS_NUM, SEQ_FPS_DEN)
PLAYBACK.SET_SURFACE(pc, surface)

-- Two distinct CDLs. Slope.r is the discriminator.
local CDL_A = {
    slope_r = 2.0, slope_g = 1.0, slope_b = 1.0,
    offset_r = 0.0, offset_g = 0.0, offset_b = 0.0,
    power_r = 1.0,  power_g = 1.0,  power_b = 1.0,
    saturation = 1.0,
}
local CDL_B = {
    slope_r = 0.5, slope_g = 1.0, slope_b = 1.0,
    offset_r = 0.0, offset_g = 0.0, offset_b = 0.0,
    power_r = 1.0,  power_g = 1.0,  power_b = 1.0,
    saturation = 1.0,
}

PLAYBACK.SET_CLIP_GRADE(pc, clips[1].clip_id, CDL_A, nil)
PLAYBACK.SET_CLIP_GRADE(pc, clips[2].clip_id, CDL_B, nil)

local CONTROL = qt_constants.CONTROL
assert(CONTROL and CONTROL.PROCESS_EVENTS)

local EPS = 1e-4
local function approx(a, b) return math.abs(a - b) < EPS end

-- Seek onto clip A — synchronous deliverFrame path. After it returns,
-- surface CDL must be A's.
PLAYBACK.SEEK(pc, math.floor(clips[1].duration / 2))
CONTROL.PROCESS_EVENTS()
local s = EMP.SURFACE_GET_GRADE_SLOPE(surface)
expect(s ~= nil, "surface has CDL after seek onto clip A")
if s then
    expect(approx(s.r, CDL_A.slope_r),
        string.format("clip A slope.r = %.3f (got %.3f)", CDL_A.slope_r, s.r))
end

-- Seek onto clip B. THIS is the bug under test: pre-fix the surface
-- still carries A's slope_r=2.0 after this seek; post-fix it shows B's
-- slope_r=0.5.
PLAYBACK.SEEK(pc, clips[1].duration + math.floor(clips[2].duration / 2))
CONTROL.PROCESS_EVENTS()
s = EMP.SURFACE_GET_GRADE_SLOPE(surface)
expect(s ~= nil, "surface has CDL after seek onto clip B")
if s then
    expect(approx(s.r, CDL_B.slope_r),
        string.format("clip B slope.r = %.3f after transition (got %.3f)",
            CDL_B.slope_r, s.r))
end

-- Cross back the other way to confirm symmetry — both transition
-- directions must rebind, not just forward.
PLAYBACK.SEEK(pc, math.floor(clips[1].duration / 2))
CONTROL.PROCESS_EVENTS()
s = EMP.SURFACE_GET_GRADE_SLOPE(surface)
expect(s ~= nil, "surface has CDL after reverse seek onto clip A")
if s then
    expect(approx(s.r, CDL_A.slope_r),
        string.format("clip A slope.r = %.3f on reverse transition (got %.3f)",
            CDL_A.slope_r, s.r))
end

PLAYBACK.CLOSE(pc)

if #failures > 0 then
    print(string.format("\nFAILED: %d assertions", #failures))
    for _, m in ipairs(failures) do print("  " .. m) end
    os.exit(1)
end
print("✅ test_playback_grade_clip_transition.lua passed")
