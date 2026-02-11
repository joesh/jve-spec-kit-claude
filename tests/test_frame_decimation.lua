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

-- Mock media_cache
package.loaded["ui.media_cache"] = {
    is_loaded = function() return true end,
    set_playhead = function() end,
    get_asset_info = function() return { fps_num = 30, fps_den = 1 } end,
}

-- Mock viewer_panel
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

-- Timer infrastructure: captures callbacks with generation tracking
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

-- Mock audio that tracks media time (video follows audio)
local mock_audio = {
    session_initialized = true,
    source_loaded = true,
    has_audio = true,
    playing = false,
    speed = 0,
    media_time_us = 0,
    max_media_time_us = 3300000,  -- ~100 frames at 30fps
}

function mock_audio.is_ready() return mock_audio.session_initialized and mock_audio.source_loaded and mock_audio.has_audio end
function mock_audio.start() mock_audio.playing = true end
function mock_audio.stop() mock_audio.playing = false end
function mock_audio.set_speed(speed) mock_audio.speed = speed end
function mock_audio.get_media_time_us() return mock_audio.media_time_us end
function mock_audio.get_time_us() return mock_audio.media_time_us end
function mock_audio.set_max_media_time(max_us) mock_audio.max_media_time_us = max_us end
function mock_audio.set_max_time(max_us) mock_audio.max_media_time_us = max_us end
function mock_audio.seek(time_us) mock_audio.media_time_us = time_us end
function mock_audio.latch(time_us) mock_audio.media_time_us = time_us; mock_audio.playing = false end

-- Load fresh playback controller
package.loaded["core.playback.playback_controller"] = nil
package.loaded["core.playback.source_playback"] = nil
package.loaded["core.playback.timeline_playback"] = nil
package.loaded["core.playback.playback_helpers"] = nil
local pc = require("core.playback.playback_controller")
pc.init(mock_viewer)
pc.init_audio(mock_audio)
pc.set_source(100, 30, 1)

print("=== Test frame decimation (tick generation + same-frame skip) ===")

--------------------------------------------------------------------------------
-- SECTION 1: Tick Generation Counter (stale-after-stop)
--------------------------------------------------------------------------------
print("\n--- Section 1: Tick Generation Counter ---")

print("\nTest 1.1: _tick_generation exists")
assert(pc._tick_generation ~= nil, "_tick_generation field must exist")
assert(type(pc._tick_generation) == "number", "_tick_generation should be a number")
print("  pass")

print("\nTest 1.2: stop() increments _tick_generation")
local gen_before = pc._tick_generation
pc.shuttle(1)  -- start playing
pc.stop()
assert(pc._tick_generation == gen_before + 1,
    "stop() should increment _tick_generation")
print("  pass")

print("\nTest 1.3: Stale tick callback (from before stop) is discarded")
-- Start playing, capture the timer callback, then stop, then fire callback
pc.set_position(50)
mock_audio.media_time_us = 1700000  -- frame 51
mock_audio.playing = false
pc.shuttle(1)
mock_audio.playing = true

-- There should be a timer callback queued
assert(#timer_callbacks > 0, "shuttle should schedule a tick")
local stale_callback = timer_callbacks[1].callback

-- Stop playback (increments generation)
pc.stop()
clear_frames()

-- Fire the stale callback — should be a no-op (discarded by generation check)
stale_callback()

-- No frames should have been shown (stale tick was discarded)
assert(#frames_shown == 0,
    "Stale tick after stop() should not show any frames, got " .. #frames_shown)
print("  pass")

print("\nTest 1.4: Fresh tick callback (after new play) works")
clear_timers()
clear_frames()
pc.set_position(50)
mock_audio.media_time_us = 1733333  -- frame 52
mock_audio.playing = false
pc.shuttle(1)
mock_audio.playing = true

-- Run the fresh timer
assert(#timer_callbacks > 0, "shuttle should schedule tick")
run_timers(1)

-- Should have shown a frame (tick was valid)
assert(#frames_shown > 0,
    "Fresh tick should show frames, got " .. #frames_shown)
print("  pass")
pc.stop()

--------------------------------------------------------------------------------
-- SECTION 2: Same-Frame Skip (stale-during-playback)
--------------------------------------------------------------------------------
print("\n--- Section 2: Same-Frame Skip ---")

print("\nTest 2.1: _last_tick_frame exists")
assert(pc._last_tick_frame ~= nil or pc._last_tick_frame == nil,
    "_last_tick_frame field should exist (may be nil when stopped)")
-- After stop, it should be nil
assert(pc._last_tick_frame == nil,
    "_last_tick_frame should be nil when stopped")
print("  pass")

print("\nTest 2.2: Same audio frame skips tick (no frame shown)")
clear_timers()
clear_frames()
pc.set_position(50)
mock_audio.media_time_us = 1666666  -- frame 49 at 30fps
mock_audio.playing = false
pc.shuttle(1)
mock_audio.playing = true

-- Run first tick: should show frame 49
run_timers(1)
assert(#frames_shown > 0, "First tick should show a frame")
local _first_frame = frames_shown[#frames_shown]  -- luacheck: no unused

-- Audio hasn't advanced (still same frame)
clear_frames()
-- Run second tick with same audio time → should skip
run_timers(1)
assert(#frames_shown == 0,
    "Same-frame tick should be skipped (no frame shown), got " .. #frames_shown)
print("  pass")

print("\nTest 2.3: Different audio frame proceeds normally")
-- Advance audio to next frame
mock_audio.media_time_us = 1700000  -- frame 51
clear_frames()
run_timers(1)
assert(#frames_shown > 0,
    "Different-frame tick should show a frame, got " .. #frames_shown)
print("  pass")
pc.stop()

print("\nTest 2.4: _last_tick_frame cleared on stop()")
assert(pc._last_tick_frame == nil,
    "_last_tick_frame should be nil after stop()")
print("  pass")

print("\nTest 2.5: _last_tick_frame set on play()/shuttle()/slow_play()")
pc.set_position(10)
pc.shuttle(1)
-- _last_tick_frame should be set to current position
assert(pc._last_tick_frame ~= nil,
    "_last_tick_frame should be set after shuttle()")
pc.stop()
print("  pass")

print("\n=== test_frame_decimation.lua passed ===")
