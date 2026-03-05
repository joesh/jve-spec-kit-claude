-- Integration test: Sync seek to gap clears frame
--
-- NSF regression test: when seeking to a gap (no clip on any track),
-- the surface must show black (clearFrame called). Before the fix,
-- the surface retained the last frame from the previous seek position.
--
-- Observable: after clearFrame, GPUVideoSurface.frameWidth/Height = 0.
-- After setFrame with real content, frameWidth/Height > 0.
--
-- Must run via: JVEEditor --test tests/integration/test_seek_gap_clears_frame.lua

require('test_env')

local env = require("integration.integration_test_env")
local EMP = env.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
local WIDGET = qt_constants.WIDGET

-- Need a surface
local ok_surf, test_surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not test_surface then
    print("  Skipping: GPU surface not available (headless?)")
    print("✅ test_seek_gap_clears_frame.lua passed (skipped)")
    return
end

print("Testing sync seek to gap clears frame...")

local passed = 0
local total = 0

local function check(cond, msg)
    total = total + 1
    if cond then
        passed = passed + 1
        print("  PASS: " .. msg)
    else
        print("  FAIL: " .. msg)
        error("Test failed: " .. msg)
    end
end

-- Create TMB with a clip at frames 0-49, gap at frames 50-99.
-- Standard media has 108 frames — duration=50 is well within bounds.
local tmb, _ = env.create_single_clip_tmb({
    pool_threads = 0,  -- sync decode
    duration = 50,
})

local pc = PLAYBACK.CREATE()
assert(pc, "test_seek_gap_clears_frame: CREATE failed")

PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, 100, 24, 1)
PLAYBACK.SET_SURFACE(pc, test_surface)

-- Clip provider: clips already loaded via create_single_clip_tmb above.
-- Provider is a no-op — TMB already has all clips for this test.
PLAYBACK.SET_CLIP_PROVIDER(pc, function(from, to, track_type) end)

-- 1. Seek to frame 10 (inside clip) — should display a frame
PLAYBACK.SEEK(pc, 10)
local w1, h1 = EMP.SURFACE_FRAME_SIZE(test_surface)
check(w1 > 0 and h1 > 0,
    string.format("Seek to clip: frame size %dx%d (expected >0x>0)", w1, h1))

-- 2. Seek to frame 60 (gap — no clip) — should clear frame
PLAYBACK.SEEK(pc, 60)
local w2, h2 = EMP.SURFACE_FRAME_SIZE(test_surface)
check(w2 == 0 and h2 == 0,
    string.format("Seek to gap: frame size %dx%d (expected 0x0)", w2, h2))

-- 3. Seek back to frame 20 (inside clip) — should display a frame again
PLAYBACK.SEEK(pc, 20)
local w3, h3 = EMP.SURFACE_FRAME_SIZE(test_surface)
check(w3 > 0 and h3 > 0,
    string.format("Seek back to clip: frame size %dx%d (expected >0x>0)", w3, h3))

-- 4. Seek to frame 0 (first frame of clip) — boundary check
PLAYBACK.SEEK(pc, 0)
local w4, h4 = EMP.SURFACE_FRAME_SIZE(test_surface)
check(w4 > 0 and h4 > 0,
    string.format("Seek to first frame: frame size %dx%d (expected >0x>0)", w4, h4))

-- 5. Seek to frame 49 (last frame of clip) — boundary check
PLAYBACK.SEEK(pc, 49)
local w5, h5 = EMP.SURFACE_FRAME_SIZE(test_surface)
check(w5 > 0 and h5 > 0,
    string.format("Seek to last clip frame: frame size %dx%d (expected >0x>0)", w5, h5))

-- 6. Seek to frame 50 (first gap frame) — boundary check
PLAYBACK.SEEK(pc, 50)
local w6, h6 = EMP.SURFACE_FRAME_SIZE(test_surface)
check(w6 == 0 and h6 == 0,
    string.format("Seek to first gap frame: frame size %dx%d (expected 0x0)", w6, h6))

-- Cleanup
PLAYBACK.CLOSE(pc)
EMP.TMB_CLOSE(tmb)

print(string.format("\n=== Results: %d/%d passed ===", passed, total))
if passed == total then
    print("✅ test_seek_gap_clears_frame.lua passed")
else
    error("Some tests failed")
end
