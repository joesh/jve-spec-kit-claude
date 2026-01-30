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

-- Test: Reverse playback must work smoothly
-- Focus on RELATIVE behavior, not absolute values (latency compensation varies)

print("=== Test reverse playback (behavioral tests) ===")

--------------------------------------------------------------------------------
-- Mock Setup
--------------------------------------------------------------------------------

local frames_shown = {}
local mock_viewer = {
    show_frame = function(idx) table.insert(frames_shown, idx) end,
    has_media = function() return true end,
    get_total_frames = function() return 300 end,
    get_fps = function() return 30 end,
    get_current_frame = function() return 0 end,
}

local scheduled_timers = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    table.insert(scheduled_timers, { interval = interval, callback = callback })
    return { stop = function() end }
end

local function clear_state()
    frames_shown = {}
    scheduled_timers = {}
end

-- Mock audio with simulated time tracking (matches real audio_playback behavior)
local mock_audio = {
    initialized = true,
    playing = false,
    media_time_us = 0,
    max_media_time_us = 10000000,
    speed = 0,
    _anchor_us = 0,
    _elapsed_us = 0,
}

function mock_audio.start()
    mock_audio.playing = true
    mock_audio._anchor_us = mock_audio.media_time_us
    mock_audio._elapsed_us = 0
end

function mock_audio.stop()
    if mock_audio.playing then
        mock_audio.media_time_us = mock_audio.get_media_time_us()
    end
    mock_audio.playing = false
end

function mock_audio.set_speed(speed)
    if mock_audio.playing then
        mock_audio._anchor_us = mock_audio.get_media_time_us()
        mock_audio._elapsed_us = 0
    end
    mock_audio.speed = speed
end

function mock_audio.get_media_time_us()
    if not mock_audio.playing then return mock_audio.media_time_us end
    local delta = mock_audio._elapsed_us * mock_audio.speed
    local result = mock_audio._anchor_us + delta
    return math.max(0, math.min(result, mock_audio.max_media_time_us))
end

function mock_audio.seek(time_us)
    mock_audio.media_time_us = time_us
    mock_audio._anchor_us = time_us
    mock_audio._elapsed_us = 0
end

function mock_audio.set_max_media_time(max_us) mock_audio.max_media_time_us = max_us end
function mock_audio.latch(time_us) mock_audio.playing = false; mock_audio.media_time_us = time_us end

local function advance_time(us) mock_audio._elapsed_us = mock_audio._elapsed_us + us end

-- Load playback controller
package.loaded["ui.playback_controller"] = nil
local pc = require("core.playback.playback_controller")
pc.init(mock_viewer)
pc.init_audio(mock_audio)

--------------------------------------------------------------------------------
-- TEST 1: Forward vs Reverse Direction
--------------------------------------------------------------------------------
print("\n--- Test 1: Direction changes sign of time delta ---")

pc.set_source(300, 30, 1)
mock_audio.seek(5000000)  -- 5 seconds
pc.set_position(150)

-- Forward 1x
pc.shuttle(1)
local t0_fwd = mock_audio.get_media_time_us()
advance_time(100000)  -- 100ms
local t1_fwd = mock_audio.get_media_time_us()
local delta_fwd = t1_fwd - t0_fwd
pc.stop()

-- Reverse 1x
mock_audio.seek(5000000)
pc.set_position(150)
pc.shuttle(-1)
local t0_rev = mock_audio.get_media_time_us()
advance_time(100000)  -- Same 100ms
local t1_rev = mock_audio.get_media_time_us()
local delta_rev = t1_rev - t0_rev
pc.stop()

print(string.format("  Forward delta: %+d us", delta_fwd))
print(string.format("  Reverse delta: %+d us", delta_rev))

assert(delta_fwd > 0, "Forward should increase time")
assert(delta_rev < 0, "Reverse should decrease time")
assert(math.abs(delta_fwd + delta_rev) < 10000,
    "Deltas should be opposite: " .. delta_fwd .. " vs " .. delta_rev)
print("  ✓ Forward and reverse deltas are opposite signs")

--------------------------------------------------------------------------------
-- TEST 2: Speed Scaling
--------------------------------------------------------------------------------
print("\n--- Test 2: Higher speed = larger delta ---")

local function measure_delta(speed_magnitude, direction)
    clear_state()
    mock_audio.seek(5000000)
    pc.set_position(150)

    -- Set speed by repeated shuttle presses
    pc.shuttle(direction)
    while pc.speed < speed_magnitude do
        pc.shuttle(direction)
    end

    local t0 = mock_audio.get_media_time_us()
    advance_time(100000)  -- 100ms
    local t1 = mock_audio.get_media_time_us()
    pc.stop()

    return math.abs(t1 - t0)
end

local delta_1x = measure_delta(1, -1)
local delta_2x = measure_delta(2, -1)
local delta_4x = measure_delta(4, -1)

print(string.format("  1x delta: %d us", delta_1x))
print(string.format("  2x delta: %d us", delta_2x))
print(string.format("  4x delta: %d us", delta_4x))

assert(delta_2x > delta_1x * 1.5, "2x should be at least 1.5x faster than 1x")
assert(delta_4x > delta_2x * 1.5, "4x should be at least 1.5x faster than 2x")
print("  ✓ Higher speeds produce larger deltas")

--------------------------------------------------------------------------------
-- TEST 3: Frame Progression in Reverse
--------------------------------------------------------------------------------
print("\n--- Test 3: Frames decrease in reverse ---")

clear_state()
pc.set_source(300, 30, 1)
mock_audio.seek(5000000)
pc.set_position(150)
pc.shuttle(-1)

frames_shown = {}
for i = 1, 30 do
    advance_time(33333)  -- ~1 frame at 30fps
    pc._tick()
end
pc.stop()

assert(#frames_shown >= 20, "Should show at least 20 frames")

local first = frames_shown[1]
local last = frames_shown[#frames_shown]
print(string.format("  Frames: %d -> %d (delta=%d)", first, last, last - first))

assert(last < first, "Last frame should be less than first in reverse")

-- Count direction of frame changes
local decreasing, increasing = 0, 0
for i = 2, #frames_shown do
    if frames_shown[i] < frames_shown[i-1] then decreasing = decreasing + 1
    elseif frames_shown[i] > frames_shown[i-1] then increasing = increasing + 1 end
end
print(string.format("  Decreasing: %d, Increasing: %d", decreasing, increasing))
assert(decreasing > increasing, "More decreasing than increasing frame transitions")
print("  ✓ Frames decrease in reverse")

--------------------------------------------------------------------------------
-- TEST 4: No Stalling
--------------------------------------------------------------------------------
print("\n--- Test 4: Continuous frame changes (no stalling) ---")

clear_state()
mock_audio.seek(8000000)  -- 8 seconds
pc.set_position(240)
pc.shuttle(-1)

frames_shown = {}
for i = 1, 100 do
    advance_time(33333)
    pc._tick()
end
pc.stop()

-- Count unique frames
local uniq = {}
for _, f in ipairs(frames_shown) do uniq[f] = true end
local unique_count = 0
for _ in pairs(uniq) do unique_count = unique_count + 1 end

print(string.format("  100 ticks, %d unique frames", unique_count))
assert(unique_count >= 30, "Should see at least 30 unique frames over 100 ticks")

-- Check for stalls (runs of >5 identical frames)
local max_run = 1
local run = 1
for i = 2, #frames_shown do
    if frames_shown[i] == frames_shown[i-1] then
        run = run + 1
        max_run = math.max(max_run, run)
    else
        run = 1
    end
end
print(string.format("  Max identical run: %d", max_run))
assert(max_run <= 5, "Should not have runs of >5 identical frames")
print("  ✓ No stalling detected")

--------------------------------------------------------------------------------
-- TEST 5: Reverse to Boundary (Latch)
--------------------------------------------------------------------------------
print("\n--- Test 5: Reverse to start latches ---")

clear_state()
mock_audio.seek(500000)  -- 0.5 seconds from start
pc.set_position(15)
pc.shuttle(-1)

local latched = false
for i = 1, 50 do
    advance_time(33333)
    pc._tick()
    if pc.latched then latched = true; break end
end

assert(latched, "Should latch at start boundary")
assert(pc.get_position() == 0, "Should be at frame 0")
assert(pc.latched_boundary == "start", "Should be 'start' boundary")
print("  ✓ Latched at start (frame 0)")

pc.stop()

--------------------------------------------------------------------------------
-- TEST 6: Time Monotonicity in Reverse
--------------------------------------------------------------------------------
print("\n--- Test 6: Time monotonically decreasing ---")

clear_state()
mock_audio.seek(5000000)
pc.set_position(150)
pc.shuttle(-1)

local times = {}
for i = 1, 50 do
    advance_time(20000)  -- 20ms increments
    table.insert(times, mock_audio.get_media_time_us())
end
pc.stop()

local violations = 0
for i = 2, #times do
    if times[i] > times[i-1] then
        violations = violations + 1
    end
end

print(string.format("  50 samples: %.3fs -> %.3fs", times[1]/1e6, times[#times]/1e6))
print(string.format("  Monotonicity violations: %d", violations))
assert(violations == 0, "Time should never increase in reverse")
print("  ✓ Time monotonically decreasing")

--------------------------------------------------------------------------------

print("\n✅ test_reverse_playback.lua passed")
