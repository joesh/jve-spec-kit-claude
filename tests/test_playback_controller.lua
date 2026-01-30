require('test_env')

-- Mock qt_constants (required by media_cache which is required by playback_controller)
local mock_qt_constants = {
    EMP = {
        ASSET_OPEN = function() return nil, { msg = "mock" } end,
        ASSET_INFO = function() return nil end,
        ASSET_CLOSE = function() end,
        READER_CREATE = function() return nil, { msg = "mock" } end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil, { msg = "mock" } end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
    },
}
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

-- Mock media_cache (playback_controller uses it for set_playhead)
package.loaded["ui.media_cache"] = {
    is_loaded = function() return true end,
    set_playhead = function() end,
    get_asset_info = function() return { fps_num = 30, fps_den = 1 } end,
}

-- Mock viewer_panel for testing (module-style calls, not method calls)
local frames_shown = {}
local mock_viewer = {
    show_frame = function(idx)
        table.insert(frames_shown, idx)
    end,
    has_media = function() return true end,
    get_total_frames = function() return 100 end,
    get_fps = function() return 30 end,
    get_current_frame = function() return 0 end,
}

-- Mock timer - synchronous execution for testing
local timer_callbacks = {}
local timer_intervals = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    table.insert(timer_callbacks, {interval = interval, callback = callback})
    table.insert(timer_intervals, interval)
end

local function run_timers(count)
    for i = 1, count do
        if #timer_callbacks > 0 then
            local t = table.remove(timer_callbacks, 1)
            t.callback()
        end
    end
end

local function clear_timers()
    timer_callbacks = {}
    timer_intervals = {}
end

local function clear_frames()
    frames_shown = {}
end

-- Helper to test that a function asserts
local function expect_assert(fn, msg)
    local ok, err = pcall(fn)
    assert(not ok, msg .. " (expected assert but got success)")
    return err
end

-- Load playback controller fresh
package.loaded["core.playback.playback_controller"] = nil
local playback = require("core.playback.playback_controller")

print("=== Test playback_controller.lua (comprehensive) ===")

--------------------------------------------------------------------------------
-- SECTION 1: Initial State
--------------------------------------------------------------------------------
print("\n--- Section 1: Initial State ---")

print("\nTest 1.1: Initial state values")
assert(playback.state == "stopped", "Should start stopped")
assert(playback.direction == 0, "Direction should be 0")
assert(playback.speed == 1, "Speed should be 1")
assert(playback.get_position() == 0, "Frame should be 0")
assert(playback.total_frames == 0, "Total frames should be 0")
-- fps, fps_num, fps_den are nil until set_source is called (no silent defaults)
assert(playback.fps == nil, "fps should be nil before set_source")
assert(playback.fps_num == nil, "fps_num should be nil before set_source")
assert(playback.fps_den == nil, "fps_den should be nil before set_source")
print("  ✓ All initial values correct")

print("\nTest 1.2: is_playing() when stopped")
assert(playback.is_playing() == false, "is_playing should be false when stopped")
print("  ✓ is_playing() returns false")

print("\nTest 1.3: get_status() when stopped")
assert(playback.get_status() == "stopped", "Status should be 'stopped'")
print("  ✓ get_status() returns 'stopped'")

--------------------------------------------------------------------------------
-- SECTION 2: Error Paths (Assert Validation)
--------------------------------------------------------------------------------
print("\n--- Section 2: Error Paths ---")

print("\nTest 2.1: init() with nil viewer_panel asserts")
local err = expect_assert(function()
    playback.init(nil)
end, "init(nil) should assert")
assert(err:match("viewer_panel is nil"), "Error should mention viewer_panel")
print("  ✓ init(nil) asserts correctly")

print("\nTest 2.2: set_source() with nil total_frames asserts")
playback.init(mock_viewer)
err = expect_assert(function()
    playback.set_source(nil, 30, 1)
end, "set_source(nil, 30, 1) should assert")
assert(err:match("total_frames must be"), "Error should mention total_frames")
print("  ✓ set_source(nil, fps_num, fps_den) asserts correctly")

print("\nTest 2.3: set_source() with nil fps_num asserts")
err = expect_assert(function()
    playback.set_source(100, nil, 1)
end, "set_source(100, nil, 1) should assert")
assert(err:match("fps_num must be"), "Error should mention fps_num")
print("  ✓ set_source(frames, nil, den) asserts correctly")

print("\nTest 2.4: set_source() with zero fps_num asserts")
err = expect_assert(function()
    playback.set_source(100, 0, 1)
end, "set_source(100, 0, 1) should assert")
assert(err:match("fps_num must be"), "Error should mention fps_num")
print("  ✓ set_source(frames, 0, den) asserts correctly")

print("\nTest 2.5: set_source() with nil fps_den asserts")
err = expect_assert(function()
    playback.set_source(100, 30, nil)
end, "set_source(100, 30, nil) should assert")
assert(err:match("fps_den must be"), "Error should mention fps_den")
print("  ✓ set_source(frames, num, nil) asserts correctly")

print("\nTest 2.5b: calc_frame_from_time_us() with nil t_us asserts")
playback.set_source(100, 30, 1)
err = expect_assert(function()
    playback.calc_frame_from_time_us(nil)
end, "calc_frame_from_time_us(nil) should assert")
assert(err:match("must be number"), "Error should mention number")
print("  ✓ calc_frame_from_time_us(nil) asserts correctly")

print("\nTest 2.5c: calc_frame_from_time_us() without fps set asserts")
-- Reset fps to nil to test validation
package.loaded["core.playback.playback_controller"] = nil
local playback_fresh = require("core.playback.playback_controller")
playback_fresh.fps_num = nil
playback_fresh.fps_den = nil
err = expect_assert(function()
    playback_fresh.calc_frame_from_time_us(1000000)
end, "calc_frame_from_time_us without fps should assert")
assert(err:match("fps not set"), "Error should mention fps not set")
print("  ✓ calc_frame_from_time_us without fps asserts correctly")
-- Restore playback for remaining tests
package.loaded["core.playback.playback_controller"] = nil
playback = require("core.playback.playback_controller")
playback.init(mock_viewer)

print("\nTest 2.5d: calc_frame_from_time_us() computes correct frames")
playback.set_source(100, 30, 1)  -- 30fps
-- At 30fps, frame 0 = 0us, frame 1 = 33333us, frame 30 = 1000000us
assert(playback.calc_frame_from_time_us(0) == 0, "0us should be frame 0")
assert(playback.calc_frame_from_time_us(33333) == 0, "33333us should be frame 0 (floor)")
assert(playback.calc_frame_from_time_us(33334) == 1, "33334us should be frame 1")
assert(playback.calc_frame_from_time_us(1000000) == 30, "1000000us should be frame 30")
print("  ✓ calc_frame_from_time_us computes correctly at 30fps")

print("\nTest 2.5e: calc_frame_from_time_us() with non-integer fps (24000/1001)")
playback.set_source(100, 24000, 1001)  -- 23.976fps
-- At 23.976fps, frame duration = 1001000000/24000 = 41708.33us
-- frame 0 at 0us, frame 24 at ~1001000us (just over 1 second)
local frame_at_1s = playback.calc_frame_from_time_us(1000000)
assert(frame_at_1s == 23, "1000000us at 23.976fps should be frame 23, got " .. frame_at_1s)
print("  ✓ calc_frame_from_time_us works with 23.976fps")

print("\nTest 2.6: shuttle() with invalid direction asserts")
playback.set_source(100, 30, 1)
err = expect_assert(function()
    playback.shuttle(0)
end, "shuttle(0) should assert")
assert(err:match("dir must be 1 or %-1"), "Error should mention valid directions")
print("  ✓ shuttle(0) asserts correctly")

print("\nTest 2.7: shuttle() with direction 2 asserts")
err = expect_assert(function()
    playback.shuttle(2)
end, "shuttle(2) should assert")
assert(err:match("dir must be 1 or %-1"), "Error should mention valid directions")
print("  ✓ shuttle(2) asserts correctly")

print("\nTest 2.8: slow_play() with invalid direction asserts")
err = expect_assert(function()
    playback.slow_play(0)
end, "slow_play(0) should assert")
assert(err:match("dir must be 1 or %-1"), "Error should mention valid directions")
print("  ✓ slow_play(0) asserts correctly")

--------------------------------------------------------------------------------
-- SECTION 3: Basic Playback Operations
--------------------------------------------------------------------------------
print("\n--- Section 3: Basic Playback ---")

-- Reset state
playback.stop()
playback.set_source(100, 30, 1)
clear_timers()
clear_frames()

print("\nTest 3.1: shuttle(1) starts forward at 1x")
playback.shuttle(1)
assert(playback.state == "playing", "Should be playing")
assert(playback.direction == 1, "Direction should be 1 (forward)")
assert(playback.speed == 1, "Speed should be 1")
assert(playback.is_playing() == true, "is_playing should be true")
print("  ✓ Forward playback started")

print("\nTest 3.2: get_status() shows forward symbol")
local status = playback.get_status()
assert(status:match(">"), "Should show forward arrow")
assert(status:match("1%.0x"), "Should show 1.0x speed")
print("  ✓ Status shows > 1.0x")

print("\nTest 3.3: stop() stops playback")
playback.stop()
assert(playback.state == "stopped", "Should be stopped")
assert(playback.direction == 0, "Direction should be 0")
assert(playback.speed == 1, "Speed should reset to 1")
assert(playback.is_playing() == false, "is_playing should be false")
print("  ✓ Playback stopped")

print("\nTest 3.4: shuttle(-1) starts reverse at 1x")
playback.shuttle(-1)
assert(playback.state == "playing", "Should be playing")
assert(playback.direction == -1, "Direction should be -1 (reverse)")
assert(playback.speed == 1, "Speed should be 1")
print("  ✓ Reverse playback started")

print("\nTest 3.5: get_status() shows reverse symbol")
status = playback.get_status()
assert(status:match("<"), "Should show reverse arrow")
print("  ✓ Status shows <")

print("\nTest 3.6: Multiple stops are idempotent")
playback.stop()
playback.stop()
playback.stop()
assert(playback.state == "stopped", "Should still be stopped")
print("  ✓ Multiple stops work")

--------------------------------------------------------------------------------
-- SECTION 4: Speed Ramping (Forward)
--------------------------------------------------------------------------------
print("\n--- Section 4: Speed Ramping Forward ---")

playback.stop()
clear_timers()

print("\nTest 4.1: L L L L ramps up to 8x")
playback.shuttle(1)  -- 1x
assert(playback.speed == 1, "Should be 1x")
playback.shuttle(1)  -- 2x
assert(playback.speed == 2, "Should be 2x")
playback.shuttle(1)  -- 4x
assert(playback.speed == 4, "Should be 4x")
playback.shuttle(1)  -- 8x
assert(playback.speed == 8, "Should be 8x")
print("  ✓ Speed ramped to 8x")

print("\nTest 4.2: L at max speed stays at 8x")
playback.shuttle(1)
assert(playback.speed == 8, "Should still be 8x")
playback.shuttle(1)
assert(playback.speed == 8, "Should still be 8x")
print("  ✓ Speed capped at 8x")

print("\nTest 4.3: J unwinds from 8x step by step")
playback.shuttle(-1)  -- 4x
assert(playback.speed == 4, "Should be 4x")
assert(playback.direction == 1, "Still forward")
playback.shuttle(-1)  -- 2x
assert(playback.speed == 2, "Should be 2x")
assert(playback.direction == 1, "Still forward")
playback.shuttle(-1)  -- 1x
assert(playback.speed == 1, "Should be 1x")
assert(playback.direction == 1, "Still forward")
print("  ✓ Unwound to 1x, still forward")

print("\nTest 4.4: J at 1x forward stops")
playback.shuttle(-1)  -- stop
assert(playback.state == "stopped", "Should be stopped")
print("  ✓ Stopped at 1x")

print("\nTest 4.5: J after stop starts reverse")
playback.shuttle(-1)
assert(playback.state == "playing", "Should be playing")
assert(playback.direction == -1, "Should be reverse")
assert(playback.speed == 1, "Should be 1x")
print("  ✓ Started reverse after stop")

--------------------------------------------------------------------------------
-- SECTION 5: Speed Ramping (Reverse)
--------------------------------------------------------------------------------
print("\n--- Section 5: Speed Ramping Reverse ---")

playback.stop()

print("\nTest 5.1: J J J J ramps reverse to 8x")
playback.shuttle(-1)  -- 1x reverse
assert(playback.direction == -1 and playback.speed == 1, "1x reverse")
playback.shuttle(-1)  -- 2x reverse
assert(playback.direction == -1 and playback.speed == 2, "2x reverse")
playback.shuttle(-1)  -- 4x reverse
assert(playback.direction == -1 and playback.speed == 4, "4x reverse")
playback.shuttle(-1)  -- 8x reverse
assert(playback.direction == -1 and playback.speed == 8, "8x reverse")
print("  ✓ Reverse ramped to 8x")

print("\nTest 5.2: L unwinds reverse back to stop")
playback.shuttle(1)  -- 4x reverse
assert(playback.speed == 4 and playback.direction == -1, "4x reverse")
playback.shuttle(1)  -- 2x reverse
assert(playback.speed == 2 and playback.direction == -1, "2x reverse")
playback.shuttle(1)  -- 1x reverse
assert(playback.speed == 1 and playback.direction == -1, "1x reverse")
playback.shuttle(1)  -- stop
assert(playback.state == "stopped", "Should stop")
print("  ✓ Unwound from 8x reverse to stop")

print("\nTest 5.3: L after stop starts forward")
playback.shuttle(1)
assert(playback.direction == 1 and playback.speed == 1, "1x forward")
print("  ✓ Started forward after unwinding reverse")

--------------------------------------------------------------------------------
-- SECTION 6: Slow Playback (K+J, K+L)
--------------------------------------------------------------------------------
print("\n--- Section 6: Slow Playback ---")

playback.stop()

print("\nTest 6.1: slow_play(1) = 0.5x forward")
playback.slow_play(1)
assert(playback.state == "playing", "Should be playing")
assert(playback.direction == 1, "Should be forward")
assert(playback.speed == 0.5, "Should be 0.5x")
print("  ✓ Slow forward at 0.5x")

print("\nTest 6.2: get_status() shows 0.5x")
status = playback.get_status()
assert(status:match("0%.5x"), "Should show 0.5x")
print("  ✓ Status shows 0.5x")

print("\nTest 6.3: slow_play(-1) = 0.5x reverse")
playback.stop()
playback.slow_play(-1)
assert(playback.direction == -1, "Should be reverse")
assert(playback.speed == 0.5, "Should be 0.5x")
print("  ✓ Slow reverse at 0.5x")

print("\nTest 6.4: Shuttle from 0.5x forward unwinds to stop")
playback.stop()
playback.slow_play(1)  -- 0.5x forward
playback.shuttle(-1)   -- opposite direction at 0.5x should stop
assert(playback.state == "stopped", "Should stop from 0.5x")
print("  ✓ Opposite shuttle from 0.5x stops")

--------------------------------------------------------------------------------
-- SECTION 7: Timer and Frame Advancement
--------------------------------------------------------------------------------
print("\n--- Section 7: Timer and Frame Advancement ---")

playback.stop()
playback.set_source(100, 30, 1)
clear_timers()
clear_frames()

print("\nTest 7.1: _tick() when stopped is no-op")
playback.state = "stopped"
local frame_before = playback.get_position()
playback._tick()
assert(playback.get_position() == frame_before, "Frame should not change")
assert(#frames_shown == 0, "No frames should be shown")
print("  ✓ _tick() when stopped does nothing")

print("\nTest 7.2: _tick() advances frame forward at 1x")
playback.set_position(50)
playback.shuttle(1)  -- 1x forward
clear_timers()
clear_frames()

playback._tick()
assert(playback.get_position() == 51, "Frame should be 51")
assert(#frames_shown == 1, "Should show 1 frame")
assert(frames_shown[1] == 51, "Should show frame 51")
print("  ✓ Frame advances by 1 at 1x")

print("\nTest 7.3: _tick() advances frame by speed at 2x")
playback.stop()
playback.set_position(50)
playback.shuttle(1)
playback.shuttle(1)  -- 2x
clear_frames()

playback._tick()
assert(playback.get_position() == 52, "Frame should be 52 (advanced by 2)")
print("  ✓ Frame advances by 2 at 2x")

print("\nTest 7.4: _tick() advances reverse")
playback.stop()
playback.set_position(50)
playback.shuttle(-1)  -- 1x reverse
clear_frames()

playback._tick()
assert(playback.get_position() == 49, "Frame should be 49")
print("  ✓ Frame decrements in reverse")

print("\nTest 7.5: Timer interval at 1x = ~33ms (1000/30)")
playback.stop()
playback.set_position(50)
playback.shuttle(1)
clear_timers()
playback._schedule_tick()
assert(#timer_intervals == 1, "Should schedule 1 timer")
assert(timer_intervals[1] == 33, "Interval should be 33ms at 30fps")
print("  ✓ Timer interval correct at 1x")

print("\nTest 7.6: Timer interval at 0.5x = ~66ms (longer for slow)")
playback.stop()
playback.set_position(50)
playback.slow_play(1)  -- 0.5x
timer_intervals = {}
playback._schedule_tick()
assert(timer_intervals[1] == 66, "Interval should be 66ms at 0.5x")
print("  ✓ Timer interval longer at 0.5x")

print("\nTest 7.7: Timer interval at 2x = ~33ms (same interval, skip frames)")
playback.stop()
playback.set_position(50)
playback.shuttle(1)
playback.shuttle(1)  -- 2x
timer_intervals = {}
playback._schedule_tick()
assert(timer_intervals[1] == 33, "Interval should be 33ms at 2x")
print("  ✓ Timer interval same at 2x (we skip frames instead)")

print("\nTest 7.8: Timer minimum interval is 16ms")
playback.stop()
playback.fps = 1000  -- Artificially high fps
playback.set_position(50)
playback.shuttle(1)
timer_intervals = {}
playback._schedule_tick()
assert(timer_intervals[1] >= 16, "Interval should be at least 16ms")
playback.fps = 30  -- Restore
print("  ✓ Timer has minimum interval of 16ms")

--------------------------------------------------------------------------------
-- SECTION 8: Boundary Conditions (Shuttle Mode = Latch at Boundary)
--------------------------------------------------------------------------------
print("\n--- Section 8: Boundary Conditions ---")

playback.stop()
playback.set_source(100, 30, 1)
clear_timers()
clear_frames()

-- NOTE: shuttle() sets transport_mode="shuttle", which LATCHES at boundaries
-- instead of stopping. This is the new JKL shuttle behavior.

print("\nTest 8.1: Latch at end boundary (frame 99)")
playback.set_position(98)
playback.shuttle(1)
clear_timers()

playback._tick()  -- 99
-- Shuttle mode latches at boundary (stays playing but frozen)
assert(playback.state == "playing", "Shuttle should stay playing (latched)")
assert(playback.latched == true, "Should be latched at boundary")
assert(playback.get_position() == 99, "Frame should be 99")
print("  ✓ Latched at end boundary")
playback.stop()

print("\nTest 8.2: Latch at start boundary (frame 0)")
playback.set_position(1)
playback.shuttle(-1)  -- reverse
clear_timers()

playback._tick()  -- 0
assert(playback.state == "playing", "Shuttle should stay playing (latched)")
assert(playback.latched == true, "Should be latched at boundary")
assert(playback.get_position() == 0, "Frame should be 0")
print("  ✓ Latched at start boundary")
playback.stop()

print("\nTest 8.3: Frame clamped when overshooting end at high speed")
playback.set_position(97)
playback.shuttle(1)
playback.shuttle(1)
playback.shuttle(1)  -- 4x forward
clear_timers()

playback._tick()  -- Would be 101, clamped to 99
assert(playback.get_position() == 99, "Frame should be clamped to 99")
assert(playback.latched == true, "Should latch at boundary")
print("  ✓ Frame clamped at end when overshooting")
playback.stop()

print("\nTest 8.4: Frame clamped when overshooting start at high speed")
playback.set_position(3)
playback.shuttle(-1)
playback.shuttle(-1)
playback.shuttle(-1)  -- 4x reverse
clear_timers()

playback._tick()  -- Would be -1, clamped to 0
assert(playback.get_position() == 0, "Frame should be clamped to 0")
assert(playback.latched == true, "Should latch at boundary")
print("  ✓ Frame clamped at start when overshooting")
playback.stop()

print("\nTest 8.5: Starting exactly at frame 0 in reverse latches immediately")
playback.set_position(0)
playback.shuttle(-1)
clear_timers()

playback._tick()  -- Can't go below 0
assert(playback.latched == true, "Should latch immediately")
assert(playback.get_position() == 0, "Frame should stay 0")
print("  ✓ Reverse from frame 0 latches immediately")
playback.stop()

print("\nTest 8.6: Starting exactly at last frame forward latches immediately")
playback.set_position(99)
playback.shuttle(1)
clear_timers()

playback._tick()  -- Already at end
assert(playback.latched == true, "Should latch immediately")
assert(playback.get_position() == 99, "Frame should stay 99")
print("  ✓ Forward from last frame latches immediately")
playback.stop()

--------------------------------------------------------------------------------
-- SECTION 9: Edge Cases
--------------------------------------------------------------------------------
print("\n--- Section 9: Edge Cases ---")

print("\nTest 9.1: set_source resets state")
playback.set_position(50)
playback.shuttle(1)
playback.shuttle(1)  -- 2x forward
playback.set_source(200, 24, 1)  -- New source
assert(playback.state == "stopped", "Should be stopped after set_source")
assert(playback.get_position() == 0, "Frame should be 0")
assert(playback.total_frames == 200, "Total frames should be 200")
assert(playback.fps == 24, "FPS should be 24")
print("  ✓ set_source resets all state")

print("\nTest 9.2: Fractional frame position with 0.5x speed")
playback.set_source(100, 30, 1)
playback.set_position(50.0)
playback.slow_play(1)  -- 0.5x forward
clear_frames()

playback._tick()  -- 50.5
assert(playback.get_position() == 50.5, "Frame should be 50.5")
assert(frames_shown[1] == 50, "Should display floor(50.5) = 50")

playback._tick()  -- 51.0
assert(playback.get_position() == 51.0, "Frame should be 51.0")
assert(frames_shown[2] == 51, "Should display 51")
print("  ✓ Fractional frame positions handled correctly")

print("\nTest 9.3: _tick() with no viewer_panel asserts (fail-fast)")
-- Temporarily clear all playback modules to get fresh state without viewer_panel
package.loaded["core.playback.playback_controller"] = nil
package.loaded["core.playback.source_playback"] = nil
package.loaded["core.playback.timeline_playback"] = nil
package.loaded["core.playback.playback_helpers"] = nil
local playback2 = require("core.playback.playback_controller")
-- Don't call init, so viewer_panel is nil
playback2.set_source = function(t, fn, fd)
    playback2.total_frames = t
    playback2.fps_num = fn
    playback2.fps_den = fd
    playback2.fps = fn / fd
    playback2._position = 0
end
playback2.set_source(100, 30, 1)
playback2.state = "playing"
playback2.direction = 1
playback2.speed = 1
playback2._position = 50

-- _tick should assert when viewer_panel is nil (fail-fast policy)
local ok, err2 = pcall(function() playback2._tick() end)
assert(not ok, "Should assert when no viewer")
assert(err2:match("viewer_panel not set"), "Should mention viewer_panel")
print("  ✓ _tick asserts when viewer_panel missing (fail-fast)")

-- Restore for remaining tests (clear all playback modules again for fresh state)
package.loaded["core.playback.playback_controller"] = nil
package.loaded["core.playback.source_playback"] = nil
package.loaded["core.playback.timeline_playback"] = nil
package.loaded["core.playback.playback_helpers"] = nil
playback = require("core.playback.playback_controller")
playback.init(mock_viewer)
playback.set_source(100, 30, 1)

print("\nTest 9.4: _schedule_tick does nothing when stopped")
playback.stop()
clear_timers()
playback._schedule_tick()
assert(#timer_callbacks == 0, "Should not schedule timer when stopped")
print("  ✓ _schedule_tick no-op when stopped")

print("\nTest 9.5: Single frame media (total_frames = 1)")
playback.set_source(1, 30, 1)
playback.set_position(0)
playback.shuttle(1)
clear_timers()
playback._tick()
-- Single frame with shuttle mode: latches at boundary (already at end)
assert(playback.latched == true, "Should latch immediately with 1 frame")
assert(playback.get_position() == 0, "Frame should stay 0")
print("  ✓ Single frame media handled (latches)")

playback.stop()

--------------------------------------------------------------------------------
-- SECTION 10: Audio Integration
--------------------------------------------------------------------------------
print("\n--- Section 10: Audio Integration ---")

-- Reload module to get fresh state
package.loaded["core.playback.playback_controller"] = nil
local pc = require("core.playback.playback_controller")
pc.init(mock_viewer)
pc.set_source(100, 30, 1)

-- Create mock audio_playback module
-- NOTE: New architecture - video QUERIES audio time, doesn't push to it
local mock_audio = {
    initialized = true,
    playing = false,
    speed = 0,
    media_time_us = 0,
    max_media_time_us = 0,
    start_count = 0,
    stop_count = 0,
    seek_count = 0,
}

function mock_audio.start()
    mock_audio.playing = true
    mock_audio.start_count = mock_audio.start_count + 1
end

function mock_audio.stop()
    mock_audio.playing = false
    mock_audio.stop_count = mock_audio.stop_count + 1
end

function mock_audio.set_speed(speed)
    mock_audio.speed = speed
end

-- New architecture: video queries audio for current time
function mock_audio.get_media_time_us()
    return mock_audio.media_time_us
end

-- New architecture: controller sets max media time for clamping
function mock_audio.set_max_media_time(max_us)
    mock_audio.max_media_time_us = max_us
end

function mock_audio.seek(time_us)
    mock_audio.media_time_us = time_us
    mock_audio.seek_count = mock_audio.seek_count + 1
end

print("\nTest 10.1: init_audio sets audio module")
pc.init_audio(mock_audio)
print("  ✓ init_audio accepted mock")

print("\nTest 10.2: shuttle starts audio")
mock_audio.start_count = 0
pc.shuttle(1)
assert(mock_audio.start_count == 1, "Audio should be started")
assert(mock_audio.speed == 1.0, "Speed should be 1.0")
print("  ✓ shuttle(1) starts audio")

print("\nTest 10.3: speed change syncs audio")
pc.shuttle(1)  -- Speed up to 2x
assert(mock_audio.speed == 2.0, "Speed should be 2.0")
print("  ✓ Speed change synced to audio")

print("\nTest 10.4: stop stops audio")
mock_audio.stop_count = 0
pc.stop()
assert(mock_audio.stop_count == 1, "Audio should be stopped")
print("  ✓ stop() stops audio")

print("\nTest 10.5: slow_play starts audio")
mock_audio.start_count = 0
pc.slow_play(-1)
assert(mock_audio.start_count == 1, "Audio should be started")
assert(mock_audio.speed == -0.5, "Speed should be -0.5")
print("  ✓ slow_play(-1) starts audio at -0.5x")
pc.stop()

print("\nTest 10.6: seek syncs audio")
mock_audio.seek_count = 0
pc.seek(50)
assert(mock_audio.seek_count == 1, "Audio seek should be called")
assert(mock_audio.media_time_us > 0, "Media time should be set")
print("  ✓ seek syncs audio position")

print("\nTest 10.7: _tick queries audio time (video follows audio)")
-- NEW ARCHITECTURE: video QUERIES audio for time, doesn't push to it
pc.set_position(10)
pc.state = "playing"
pc.direction = 1
pc.speed = 1
mock_audio.playing = true
-- Simulate audio at 500ms (frame ~15 at 30fps)
mock_audio.media_time_us = 500000
clear_frames()
pc._tick()
-- Video should have read audio time and calculated frame from it
-- 500000us at 30fps = frame 15
assert(pc.get_position() == 15, "Frame should follow audio time (15), got: " .. pc.get_position())
assert(#frames_shown >= 1, "Should show frame")
assert(frames_shown[1] == 15, "Should display frame 15")
print("  ✓ _tick queries audio time, video follows audio")

pc.stop()

-- Clean up audio reference
pc.init_audio(nil)

print("\n✅ test_playback_controller.lua passed (all paths covered)")
