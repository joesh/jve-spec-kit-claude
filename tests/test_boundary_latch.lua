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
        SET_DECODE_MODE = function() end,
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

-- Test: Boundary latch for shuttle mode
-- In shuttle mode, hitting start/end should LATCH (time stops) instead of stopping transport.
-- Normal play mode still stops at boundaries.

-- Mock viewer_panel
local frames_shown = {}
local mock_viewer = {
    show_frame = function(idx) table.insert(frames_shown, idx) end,
    has_media = function() return true end,
    get_total_frames = function() return 100 end,
    get_fps = function() return 30 end,
    get_current_frame = function() return 0 end,
}

-- Mock timer - synchronous execution for testing
local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    table.insert(timer_callbacks, {interval = interval, callback = callback})
end

local function run_timers(count)
    for i = 1, count do
        if #timer_callbacks > 0 then
            local t = table.remove(timer_callbacks, 1)
            t.callback()
        end
    end
end

local function clear_timers() timer_callbacks = {} end
local function clear_frames() frames_shown = {} end

-- Mock audio_playback module with latch support
local mock_audio = {
    session_initialized = true,
    source_loaded = true,
    has_audio = true,
    playing = false,
    media_time_us = 0,
    max_media_time_us = 0,
    speed = 0,
    latched = false,
    latch_time_us = nil,
}

function mock_audio.is_ready() return mock_audio.session_initialized and mock_audio.source_loaded and mock_audio.has_audio end
function mock_audio.shutdown_session() mock_audio.session_initialized = false; mock_audio.source_loaded = false end
function mock_audio.start() mock_audio.playing = true end
function mock_audio.stop() mock_audio.playing = false end
function mock_audio.set_speed(speed) mock_audio.speed = speed end
function mock_audio.get_media_time_us() return mock_audio.media_time_us end
function mock_audio.set_max_media_time(max_us) mock_audio.max_media_time_us = max_us end
function mock_audio.set_max_time(max_us) mock_audio.max_media_time_us = max_us end
function mock_audio.set_audio_sources() end
mock_audio.get_time_us = mock_audio.get_media_time_us
function mock_audio.seek(time_us)
    mock_audio.media_time_us = time_us
    mock_audio.latched = false
end
function mock_audio.latch(time_us)
    mock_audio.latched = true
    mock_audio.latch_time_us = time_us
    mock_audio.playing = false
    mock_audio.media_time_us = time_us
end

-- Load playback controller fresh
package.loaded["ui.playback_controller"] = nil
local pc = require("core.playback.playback_controller")
pc.init(mock_viewer)
pc.init_audio(mock_audio)

print("=== Test boundary latch ===")

--------------------------------------------------------------------------------
-- SECTION 1: Transport mode tracking
--------------------------------------------------------------------------------
print("\n--- Section 1: Transport mode tracking ---")

print("\nTest 1.1: transport_mode initialized to 'none'")
assert(pc.transport_mode == "none", "transport_mode should be 'none' initially")
print("  ok transport_mode = 'none'")

print("\nTest 1.2: shuttle sets transport_mode to 'shuttle'")
pc.set_source(100, 30, 1)
pc.shuttle(1)
assert(pc.transport_mode == "shuttle", "transport_mode should be 'shuttle' after shuttle()")
pc.stop()
print("  ok shuttle() sets transport_mode = 'shuttle'")

print("\nTest 1.3: slow_play sets transport_mode to 'shuttle'")
pc.slow_play(1)
assert(pc.transport_mode == "shuttle", "transport_mode should be 'shuttle' after slow_play()")
pc.stop()
print("  ok slow_play() sets transport_mode = 'shuttle'")

print("\nTest 1.4: stop clears transport_mode to 'none'")
pc.shuttle(1)
pc.stop()
assert(pc.transport_mode == "none", "transport_mode should be 'none' after stop()")
print("  ok stop() clears transport_mode = 'none'")

--------------------------------------------------------------------------------
-- SECTION 2: Latch at end boundary
--------------------------------------------------------------------------------
print("\n--- Section 2: Latch at end boundary ---")

pc.set_source(100, 30, 1)  -- 100 frames at 30fps
clear_timers()
clear_frames()
mock_audio.media_time_us = 0
mock_audio.latched = false

print("\nTest 2.1: Shuttle forward to end latches (does not stop)")
-- Position near end
pc.set_position(98)
mock_audio.media_time_us = math.floor(98 * 1000000 * 1 / 30)  -- frame 98 time
pc.shuttle(1)
clear_timers()

-- Simulate tick that hits boundary
mock_audio.media_time_us = math.floor(99 * 1000000 * 1 / 30)  -- frame 99 time
pc._tick()

-- Should be latched, NOT stopped
assert(pc.state == "playing", "state should remain 'playing' (latched, not stopped)")
assert(pc.latched == true, "latched should be true")
assert(pc.latched_boundary == "end", "latched_boundary should be 'end'")
assert(pc.get_position() == 99, "frame should be at end (99)")
assert(mock_audio.latched == true, "audio should be latched")
print("  ok shuttled to end, latched at frame 99")

print("\nTest 2.2: While latched, ticks don't advance frame")
local frame_before = pc.get_position()
pc._tick()
pc._tick()
pc._tick()
assert(pc.get_position() == frame_before, "frame should not advance while latched")
assert(pc.state == "playing", "should still be playing (latched)")
print("  ok frame constant while latched")

print("\nTest 2.3: Opposite direction while latched unlatches and resumes")
pc.shuttle(-1)  -- Press J while latched at end
assert(pc.latched == false, "should unlatch on opposite direction")
assert(pc.direction == -1, "should be going reverse now")
assert(pc.state == "playing", "should still be playing")
assert(mock_audio.latched == false, "audio should be unlatched")
print("  ok J unlatched and resumed reverse")
pc.stop()

--------------------------------------------------------------------------------
-- SECTION 3: Latch at start boundary
--------------------------------------------------------------------------------
print("\n--- Section 3: Latch at start boundary ---")

pc.set_source(100, 30, 1)
clear_timers()
mock_audio.latched = false

print("\nTest 3.1: Shuttle reverse to start latches")
pc.set_position(1)
mock_audio.media_time_us = math.floor(1 * 1000000 * 1 / 30)
pc.shuttle(-1)
clear_timers()

-- Simulate tick hitting start
mock_audio.media_time_us = 0
pc._tick()

assert(pc.state == "playing", "state should remain 'playing'")
assert(pc.latched == true, "should be latched")
assert(pc.latched_boundary == "start", "latched_boundary should be 'start'")
assert(pc.get_position() == 0, "frame should be at start (0)")
print("  ok shuttled reverse to start, latched at frame 0")

print("\nTest 3.2: L (forward) while latched at start unlatches")
pc.shuttle(1)  -- Press L while latched at start
assert(pc.latched == false, "should unlatch")
assert(pc.direction == 1, "should be going forward")
print("  ok L unlatched and resumed forward")
pc.stop()

--------------------------------------------------------------------------------
-- SECTION 4: Seek clears latch
--------------------------------------------------------------------------------
print("\n--- Section 4: Seek clears latch ---")

print("\nTest 4.1: Seek while latched clears latch")
pc.set_source(100, 30, 1)
pc.set_position(98)
mock_audio.media_time_us = math.floor(98 * 1000000 * 1 / 30)
pc.shuttle(1)
clear_timers()

-- Hit end boundary
mock_audio.media_time_us = math.floor(99 * 1000000 * 1 / 30)
pc._tick()
assert(pc.latched == true, "should be latched at end")

-- Seek
pc.seek(50)
assert(pc.latched == false, "seek should clear latch")
assert(pc.get_position() == 50, "frame should be 50")
print("  ok seek clears latch")
pc.stop()

--------------------------------------------------------------------------------
-- SECTION 5: Normal play mode stops at boundary (not latch)
--------------------------------------------------------------------------------
print("\n--- Section 5: Normal play stops at boundary ---")

print("\nTest 5.1: Play mode (transport_mode='play') stops at end, does not latch")
-- This test is for future play() function; for now shuttle is the only play mode
-- Skip if play() doesn't exist yet
if pc.play then
    pc.set_source(100, 30, 1)
    pc.set_position(98)
    mock_audio.media_time_us = math.floor(98 * 1000000 * 1 / 30)
    pc.play()  -- Normal play
    clear_timers()

    mock_audio.media_time_us = math.floor(99 * 1000000 * 1 / 30)
    pc._tick()

    assert(pc.state == "stopped", "normal play should stop at boundary, not latch")
    assert(pc.latched == false or pc.latched == nil, "should not be latched")
    print("  ok normal play stops at boundary")
else
    print("  (skipped - play() not implemented)")
end

--------------------------------------------------------------------------------
-- SECTION 6: Latch time is frame-derived
--------------------------------------------------------------------------------
print("\n--- Section 6: Latch time is frame-derived ---")

print("\nTest 6.1: Latch time computed from frame, not sampled from AOP")
pc.set_source(100, 30, 1)
pc.set_position(98)
mock_audio.media_time_us = math.floor(98 * 1000000 * 1 / 30)
pc.shuttle(1)
clear_timers()

-- Hit boundary
mock_audio.media_time_us = math.floor(99 * 1000000 * 1 / 30)
pc._tick()

-- Check that latch time was computed from frame 99 (not sampled)
-- At 30fps, frame 99 = 99 * 1000000 / 30 = 3300000us
local expected_latch_time = math.floor(99 * 1000000 * 1 / 30)
assert(mock_audio.latch_time_us == expected_latch_time,
    "latch time should be frame-derived: expected " .. expected_latch_time ..
    ", got " .. tostring(mock_audio.latch_time_us))
print("  ok latch time = " .. expected_latch_time .. "us (frame-derived)")
pc.stop()

print("\n ok test_boundary_latch.lua passed")
