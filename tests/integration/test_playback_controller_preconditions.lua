-- Integration test: PlaybackController precondition validation
-- NSF: Verifies that PlaybackController asserts on invalid usage patterns.
--
-- NOTE: We can't easily test that asserts fire (they abort), so this test
-- verifies the VALID usage patterns work correctly. The implementation
-- should crash on invalid patterns during development.
require('test_env')

print("Testing PlaybackController preconditions...")

-- Skip if qt_constants not available
if not qt_constants then
    print("  ⚠ Skipping: qt_constants not available")
    print("✅ test_playback_controller_preconditions.lua passed (skipped)")
    return
end

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

local function section(name)
    print("\n-- " .. name .. " --")
end

local EMP = qt_constants.EMP
local PLAYBACK = qt_constants.PLAYBACK

--------------------------------------------------------------------------------
-- 1. Valid usage: full setup before Play
--------------------------------------------------------------------------------
section("1. Valid usage: full setup sequence")
do
    local pc = PLAYBACK.CREATE()
    local tmb = EMP.TMB_CREATE(2)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, 24, 1)

    -- Proper sequence: bounds → TMB → tracks → play
    PLAYBACK.SET_BOUNDS(pc, 1000, 24, 1)
    PLAYBACK.SET_TMB(pc, tmb)
    PLAYBACK.SET_VIDEO_TRACKS(pc, {0})

    -- Now Play should work
    PLAYBACK.PLAY(pc, 1, 1.0)
    check(PLAYBACK.IS_PLAYING(pc) == true, "Play succeeds after proper setup")

    PLAYBACK.STOP(pc)
    PLAYBACK.CLOSE(pc)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 2. Seek requires bounds
--------------------------------------------------------------------------------
section("2. Seek with bounds set")
do
    local pc = PLAYBACK.CREATE()

    -- Set bounds first (required for seek to make sense)
    PLAYBACK.SET_BOUNDS(pc, 500, 30, 1)

    -- Seek should work
    PLAYBACK.SEEK(pc, 100)
    check(PLAYBACK.CURRENT_FRAME(pc) == 100, "Seek works with bounds set")

    -- Seek to boundary
    PLAYBACK.SEEK(pc, 0)
    check(PLAYBACK.CURRENT_FRAME(pc) == 0, "Seek to 0 works")

    PLAYBACK.CLOSE(pc)
end

--------------------------------------------------------------------------------
-- 3. SetBounds validates positive values
--------------------------------------------------------------------------------
section("3. SetBounds requires positive values")
do
    local pc = PLAYBACK.CREATE()

    -- Valid bounds
    PLAYBACK.SET_BOUNDS(pc, 100, 24, 1)
    check(true, "SetBounds(100, 24, 1) accepted")

    -- Note: SetBounds with fps_num=0, fps_den=0, or total_frames=0
    -- should assert and crash. We can't test assert failures in Lua,
    -- but the implementation MUST fail-fast on these invalid inputs.

    PLAYBACK.CLOSE(pc)
end

--------------------------------------------------------------------------------
-- 4. Play validates direction and speed
--------------------------------------------------------------------------------
section("4. Play validates parameters")
do
    local pc = PLAYBACK.CREATE()
    PLAYBACK.SET_BOUNDS(pc, 1000, 24, 1)

    -- Valid: direction=1, speed=1.0
    PLAYBACK.PLAY(pc, 1, 1.0)
    PLAYBACK.STOP(pc)
    check(true, "Play(1, 1.0) accepted")

    -- Valid: direction=-1 (reverse)
    PLAYBACK.PLAY(pc, -1, 1.0)
    PLAYBACK.STOP(pc)
    check(true, "Play(-1, 1.0) accepted")

    -- Valid: speed=2.0 (shuttle)
    PLAYBACK.PLAY(pc, 1, 2.0)
    PLAYBACK.STOP(pc)
    check(true, "Play(1, 2.0) accepted")

    -- Note: Play(0, 1.0) or Play(1, -1.0) should assert.
    -- We can't test this without crashing.

    PLAYBACK.CLOSE(pc)
end

--------------------------------------------------------------------------------
-- 5. Shuttle mode and boundary detection
--------------------------------------------------------------------------------
section("5. Shuttle mode boundary latch")
do
    local pc = PLAYBACK.CREATE()
    PLAYBACK.SET_BOUNDS(pc, 100, 24, 1)

    -- Initially not at boundary
    check(PLAYBACK.HIT_BOUNDARY(pc) == false, "HIT_BOUNDARY initially false")

    -- Enable shuttle mode
    PLAYBACK.SET_SHUTTLE_MODE(pc, true)

    -- Seek to end
    PLAYBACK.SEEK(pc, 99)
    check(PLAYBACK.CURRENT_FRAME(pc) == 99, "Seeked to frame 99")

    -- HIT_BOUNDARY is set by the tick loop, not by seek
    -- So it should still be false after seek
    check(PLAYBACK.HIT_BOUNDARY(pc) == false, "HIT_BOUNDARY false after seek (set by tick)")

    PLAYBACK.CLOSE(pc)
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n=== Results: %d/%d passed ===", passed, total))
if passed == total then
    print("✅ test_playback_controller_preconditions.lua passed")
else
    error("Some tests failed")
end
