--- Test: seek during playback restarts audio (no stale time)
--
-- Regression: During playback, user clicks timeline to reposition playhead.
-- seek() calls audio_playback.seek() (reanchor), but the audio hardware buffer
-- still has old samples. Next _tick() reads stale time from get_media_time_us()
-- and overwrites the user's click position.
--
-- The fix: seek() during playback must stop → seek → start audio so the
-- pipeline is fully flushed and the next tick reads correct time.

require("test_env")

print("=== test_seek_during_playback.lua ===")

-- Mock qt_constants
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

-- Mock logger
package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Mock media_cache
package.loaded["core.media.media_cache"] = {
    is_loaded = function() return true end,
    set_playhead = function() end,
    get_asset_info = function() return { fps_num = 30, fps_den = 1 } end,
    stop_all_prefetch = function() end,
}

-- Mock viewer
local frames_shown = {}
local mock_viewer = {
    show_frame = function(idx) table.insert(frames_shown, idx) end,
    has_media = function() return true end,
}

-- Prevent timer recursion
_G.qt_create_single_shot_timer = function() end

-- Track audio lifecycle
local audio_events = {}
local mock_audio_time_us = 0

local mock_audio = {
    session_initialized = true,
    source_loaded = true,
    has_audio = true,
    playing = false,
    speed = 0,
    media_time_us = 0,
    max_media_time_us = 0,
}

function mock_audio.is_ready() return true end
function mock_audio.set_max_media_time(v) mock_audio.max_media_time_us = v end
function mock_audio.set_max_time(v) mock_audio.max_media_time_us = v end
function mock_audio.set_audio_sources() end
mock_audio.get_time_us = mock_audio.get_media_time_us

function mock_audio.start()
    mock_audio.playing = true
    table.insert(audio_events, "start")
    -- After start, get_media_time_us reflects the last seek position
    mock_audio_time_us = mock_audio.media_time_us
end

function mock_audio.stop()
    mock_audio.playing = false
    table.insert(audio_events, "stop")
end

function mock_audio.seek(time_us)
    mock_audio.media_time_us = time_us
    table.insert(audio_events, "seek:" .. time_us)
    -- After seek+start, get_media_time_us should reflect new position.
    -- But if only seek (no stop/start), hardware buffer is stale.
end

function mock_audio.set_speed(speed)
    mock_audio.speed = speed
    table.insert(audio_events, "speed:" .. speed)
end

function mock_audio.get_media_time_us()
    return mock_audio_time_us
end

-- Load playback_controller fresh
package.loaded["core.playback.playback_controller"] = nil
package.loaded["core.playback.source_playback"] = nil
package.loaded["core.playback.timeline_playback"] = nil
package.loaded["core.playback.playback_helpers"] = nil
local pc = require("core.playback.playback_controller")

pc.init(mock_viewer)
pc.init_audio(mock_audio)
pc.set_source(1000, 30, 1)  -- 1000 frames @ 30fps

--------------------------------------------------------------------------------
-- Test 1: Source mode — seek during playback stops and restarts audio
--------------------------------------------------------------------------------
print("Test 1: source mode seek during playback stops+restarts audio")

-- Start playback at frame 0
pc.set_position(0)
pc.shuttle(1)
assert(pc.state == "playing", "Should be playing")
assert(mock_audio.playing, "Audio should be playing")

-- Simulate audio advancing to 1s (frame 30)
mock_audio_time_us = 1000000  -- audio hardware reports 1s

-- User clicks to seek to frame 500 (~16.67s)
audio_events = {}
pc.seek(500)

-- Verify audio was stopped, seeked, and restarted
local saw_stop = false
local saw_seek_to_target = false
local saw_start = false
for _, ev in ipairs(audio_events) do
    if ev == "stop" then saw_stop = true end
    if ev:match("^seek:") then saw_seek_to_target = true end
    if ev == "start" then saw_start = true end
end

assert(saw_stop, "Audio must be stopped before seek during playback, events: " .. table.concat(audio_events, ", "))
assert(saw_seek_to_target, "Audio must be seeked to new position")
assert(saw_start, "Audio must be restarted after seek, events: " .. table.concat(audio_events, ", "))

-- After restart, get_media_time_us should reflect new position
-- (our mock sets mock_audio_time_us on start)
local reported_time = mock_audio.get_media_time_us()
local expected_time = math.floor(500 * 1000000 / 30)
assert(reported_time == expected_time,
    string.format("After seek+restart, audio should report %dus, got %dus", expected_time, reported_time))

-- Verify playback still running
assert(pc.state == "playing", "Should still be playing after seek")

-- Next tick should use the new audio time, not the old stale time (~frame 30).
-- Frame↔time rounding may lose 1 frame (500→16666666us→frame 499), that's fine.
-- The critical invariant: we must NOT snap back to the pre-seek position (~30).
frames_shown = {}
pc._tick()
local tick_frame = pc.get_position()
assert(tick_frame >= 499 and tick_frame <= 500,
    string.format("After seek to 500, next tick should show ~500, got %d (stale audio would give ~30)", tick_frame))

print("  events: " .. table.concat(audio_events, ", "))
print("  ✓ audio stop→seek→start, tick reads correct position")

pc.stop()

--------------------------------------------------------------------------------
-- Test 2: Seek while stopped — no stop/start cycle needed
--------------------------------------------------------------------------------
print("Test 2: source mode seek while stopped — just seeks audio")

assert(pc.state == "stopped", "Should be stopped")
audio_events = {}
pc.seek(200)

-- Should just seek, no stop/start
local has_stop = false
local has_start = false
for _, ev in ipairs(audio_events) do
    if ev == "stop" then has_stop = true end
    if ev == "start" then has_start = true end
end

assert(not has_stop, "Should NOT stop audio when already stopped")
assert(not has_start, "Should NOT start audio when stopped")
print("  ✓ no stop/start when already stopped")

--------------------------------------------------------------------------------
print()
print("✅ test_seek_during_playback.lua passed")
