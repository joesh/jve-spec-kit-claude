-- Test PlaybackController Lua bindings
-- NOTE: Requires C++ Qt context. Skips gracefully in standalone Lua tests.
require('test_env')

print("Testing PlaybackController bindings...")

-- Skip if qt_constants not available (standalone Lua tests)
if not qt_constants then
    print("  ⚠ Skipping: qt_constants not available (requires C++ Qt context)")
    print("✅ test_playback_controller_bindings.lua passed (skipped - no Qt context)")
    return
end

-- Test 1: PLAYBACK namespace exists
assert(qt_constants.PLAYBACK, "PLAYBACK namespace should exist in qt_constants")
assert(qt_constants.PLAYBACK.CREATE, "PLAYBACK.CREATE should exist")
assert(qt_constants.PLAYBACK.CLOSE, "PLAYBACK.CLOSE should exist")
assert(qt_constants.PLAYBACK.SET_SURFACE, "PLAYBACK.SET_SURFACE should exist")
assert(qt_constants.PLAYBACK.SET_TMB, "PLAYBACK.SET_TMB should exist")
assert(qt_constants.PLAYBACK.SET_VIDEO_TRACKS, "PLAYBACK.SET_VIDEO_TRACKS should exist")
assert(qt_constants.PLAYBACK.SET_BOUNDS, "PLAYBACK.SET_BOUNDS should exist")
assert(qt_constants.PLAYBACK.PLAY, "PLAYBACK.PLAY should exist")
assert(qt_constants.PLAYBACK.STOP, "PLAYBACK.STOP should exist")
assert(qt_constants.PLAYBACK.SEEK, "PLAYBACK.SEEK should exist")
assert(qt_constants.PLAYBACK.SET_SHUTTLE_MODE, "PLAYBACK.SET_SHUTTLE_MODE should exist")
assert(qt_constants.PLAYBACK.HIT_BOUNDARY, "PLAYBACK.HIT_BOUNDARY should exist")
assert(qt_constants.PLAYBACK.CURRENT_FRAME, "PLAYBACK.CURRENT_FRAME should exist")
assert(qt_constants.PLAYBACK.IS_PLAYING, "PLAYBACK.IS_PLAYING should exist")
assert(qt_constants.PLAYBACK.SET_POSITION_CALLBACK, "PLAYBACK.SET_POSITION_CALLBACK should exist")
print("  ✓ All PLAYBACK functions exist")

-- Test 2: Create controller
local pc = qt_constants.PLAYBACK.CREATE()
assert(pc, "PLAYBACK.CREATE should return controller handle")
print("  ✓ Created PlaybackController")

-- Test 3: Initial state
local is_playing = qt_constants.PLAYBACK.IS_PLAYING(pc)
assert(is_playing == false, "New controller should not be playing")
print("  ✓ Initial state: not playing")

local frame = qt_constants.PLAYBACK.CURRENT_FRAME(pc)
assert(frame == 0, "Initial frame should be 0")
print("  ✓ Initial frame: 0")

-- Test 4: Set bounds
qt_constants.PLAYBACK.SET_BOUNDS(pc, 1000, 24, 1)
print("  ✓ Set bounds: 1000 frames @ 24fps")

-- Test 5: Set video tracks
qt_constants.PLAYBACK.SET_VIDEO_TRACKS(pc, {0})
print("  ✓ Set video tracks: {0}")

-- Test 6: Seek
qt_constants.PLAYBACK.SEEK(pc, 100)
frame = qt_constants.PLAYBACK.CURRENT_FRAME(pc)
assert(frame == 100, string.format("After seek, frame should be 100, got %d", frame))
print("  ✓ Seek to frame 100")

-- Test 7: Shuttle mode flag
qt_constants.PLAYBACK.SET_SHUTTLE_MODE(pc, true)
print("  ✓ Set shuttle mode")

-- Test 8: Boundary flag (should be false after seek)
local hit = qt_constants.PLAYBACK.HIT_BOUNDARY(pc)
assert(hit == false, "HIT_BOUNDARY should be false after seek")
print("  ✓ HIT_BOUNDARY: false")

-- Test 9: Close (no error)
qt_constants.PLAYBACK.CLOSE(pc)
print("  ✓ Closed controller")

print("✅ test_playback_controller_bindings.lua passed")
