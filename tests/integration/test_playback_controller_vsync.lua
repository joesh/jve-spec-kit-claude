-- Integration test: PlaybackController API smoke test
-- Verifies the CVDisplayLink-based PlaybackController can be created,
-- configured, started, and stopped without crashes.
--
-- NOTE: Full VSync timing verification requires the Qt event loop to be
-- running, which doesn't happen during script-based integration tests.
-- The actual VSync-locked behavior is verified manually or in the running app.
require('test_env')

print("Testing PlaybackController CVDisplayLink smoke test...")

-- Skip if qt_constants not available
if not qt_constants then
    print("  ⚠ Skipping: qt_constants not available (requires C++ Qt context)")
    print("✅ test_playback_controller_vsync.lua passed (skipped - no Qt context)")
    return
end

-- Create GPU video surface (required by SET_SURFACE type check)
local WIDGET = qt_constants.WIDGET
if not WIDGET or not WIDGET.CREATE_GPU_VIDEO_SURFACE then
    print("  ⚠ Skipping: CREATE_GPU_VIDEO_SURFACE not available")
    print("✅ test_playback_controller_vsync.lua passed (skipped)")
    return
end
local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not surface then
    print("  ⚠ Skipping: GPU video surface creation failed (headless?)")
    print("✅ test_playback_controller_vsync.lua passed (skipped)")
    return
end
print("  ✓ Created GPU video surface")

-- Create controller
local pc = qt_constants.PLAYBACK.CREATE()
assert(pc, "Failed to create PlaybackController")
print("  ✓ Created PlaybackController")

-- Create TMB for frame delivery
local EMP = qt_constants.EMP
local tmb = EMP.TMB_CREATE(2)
assert(tmb, "Failed to create TMB")
EMP.TMB_SET_SEQUENCE_RATE(tmb, 24, 1)
print("  ✓ Created TMB")

-- Set up controller
qt_constants.PLAYBACK.SET_TMB(pc, tmb)
qt_constants.PLAYBACK.SET_BOUNDS(pc, 1000, 24, 1)
qt_constants.PLAYBACK.SET_SURFACE(pc, surface)
print("  ✓ Configured controller (TMB, bounds, surface)")

-- Set position callback
qt_constants.PLAYBACK.SET_POSITION_CALLBACK(pc, function(_, _)
    -- Callback would fire during event loop (not during test)
end)
print("  ✓ Set position callback")

-- Verify initial state
assert(qt_constants.PLAYBACK.IS_PLAYING(pc) == false, "Should not be playing initially")
assert(qt_constants.PLAYBACK.CURRENT_FRAME(pc) == 0, "Should be at frame 0 initially")
print("  ✓ Initial state: not playing, frame 0")

-- Start playback (this starts CVDisplayLink)
qt_constants.PLAYBACK.PLAY(pc, 1, 1.0)
assert(qt_constants.PLAYBACK.IS_PLAYING(pc) == true, "Should be playing after PLAY")
print("  ✓ Started playback (CVDisplayLink running)")

-- Stop immediately (tests CVDisplayLink stop path)
qt_constants.PLAYBACK.STOP(pc)
assert(qt_constants.PLAYBACK.IS_PLAYING(pc) == false, "Should not be playing after STOP")
print("  ✓ Stopped playback (CVDisplayLink stopped)")

-- Test shuttle mode
qt_constants.PLAYBACK.SET_SHUTTLE_MODE(pc, true)
assert(qt_constants.PLAYBACK.HIT_BOUNDARY(pc) == false, "Should not have hit boundary")
print("  ✓ Shuttle mode: enabled, no boundary hit")

-- Test seek
qt_constants.PLAYBACK.SEEK(pc, 500)
assert(qt_constants.PLAYBACK.CURRENT_FRAME(pc) == 500, "Should be at frame 500 after seek")
print("  ✓ Seek to frame 500")

-- Clean up
qt_constants.PLAYBACK.CLOSE(pc)
EMP.TMB_CLOSE(tmb)
print("  ✓ Cleaned up resources")

print("✅ test_playback_controller_vsync.lua passed")
