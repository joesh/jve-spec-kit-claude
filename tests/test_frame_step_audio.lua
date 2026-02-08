require('test_env')

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
    SSE = {
        CREATE = function() return "mock_sse" end,
        RESET = function() end,
        SET_TARGET = function() end,
        PUSH_PCM = function() end,
        RENDER_ALLOC = function(sse, frames) return "mock_pcm", frames end,
        CURRENT_TIME_US = function() return 0 end,
        STARVED = function() return false end,
        CLEAR_STARVED = function() end,
        CLOSE = function() end,
    },
    AOP = {
        OPEN = function() return "mock_aop" end,
        CLOSE = function() end,
        START = function() end,
        STOP = function() end,
        FLUSH = function() end,
        WRITE_F32 = function(aop, pcm, frames) return frames end,
        PLAYHEAD_US = function() return 0 end,
        BUFFERED_FRAMES = function() return 0 end,
        HAD_UNDERRUN = function() return false end,
        CLEAR_UNDERRUN = function() end,
        SAMPLE_RATE = function() return 48000 end,
        CHANNELS = function() return 2 end,
    },
}
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

-- Mock media_cache
package.loaded["ui.media_cache"] = {
    is_loaded = function() return true end,
    set_playhead = function() end,
    get_asset_info = function() return { fps_num = 30, fps_den = 1, has_audio = true, audio_sample_rate = 48000, duration_us = 3333333 } end,
    get_file_path = function() return "/mock/media.mov" end,
    ensure_audio_pooled = function() return { has_audio = true, audio_sample_rate = 48000, duration_us = 3333333 } end,
    get_audio_pcm_for_path = function(path, start_us, end_us, sr) return "mock_pcm_ptr", 1024, start_us end,
}

-- Mock viewer_panel
local mock_viewer = {
    show_frame = function() end,
    has_media = function() return true end,
    get_total_frames = function() return 100 end,
    get_fps = function() return 30 end,
    get_current_frame = function() return 0 end,
}

-- Timer infrastructure
local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    table.insert(timer_callbacks, {interval = interval, callback = callback})
end

local function clear_timers()
    timer_callbacks = {}
end

print("=== Test frame step audio (play_burst + arrow key integration) ===")

--------------------------------------------------------------------------------
-- SECTION 1: audio_playback.play_burst exists and works
--------------------------------------------------------------------------------
print("\n--- Section 1: audio_playback.play_burst ---")

-- Load audio_playback fresh
package.loaded["core.media.audio_playback"] = nil
local audio_pb = require("core.media.audio_playback")

-- Track AOP calls to verify burst sequence
local aop_calls = {}
local original_aop_start = mock_qt_constants.AOP.START
local original_aop_stop = mock_qt_constants.AOP.STOP
local original_aop_flush = mock_qt_constants.AOP.FLUSH
local original_aop_write = mock_qt_constants.AOP.WRITE_F32

mock_qt_constants.AOP.START = function(...)
    table.insert(aop_calls, "START")
    return original_aop_start(...)
end
mock_qt_constants.AOP.STOP = function(...)
    table.insert(aop_calls, "STOP")
    return original_aop_stop(...)
end
mock_qt_constants.AOP.FLUSH = function(...)
    table.insert(aop_calls, "FLUSH")
    return original_aop_flush(...)
end
mock_qt_constants.AOP.WRITE_F32 = function(...)
    table.insert(aop_calls, "WRITE_F32")
    return original_aop_write(...)
end

print("\nTest 1.1: play_burst function exists")
assert(type(audio_pb.play_burst) == "function",
    "audio_playback must have play_burst function")
print("  pass")

print("\nTest 1.2: play_burst bails when not initialized")
assert(not audio_pb.session_initialized, "Should not be initialized yet")
-- Should not error, just bail
audio_pb.play_burst(0, 33333)
print("  pass")

print("\nTest 1.3: play_burst bails when playing")
-- Init session first
audio_pb.init_session(48000, 2)
assert(audio_pb.session_initialized, "Should be initialized")
audio_pb.set_max_time(3333333)

-- Set sources so has_audio is true
local mock_cache = {
    get_audio_pcm_for_path = function(path, start_us, end_us, sr)
        return "mock_pcm", 1024, start_us
    end,
}
audio_pb.set_audio_sources({{
    path = "/mock/media.mov",
    source_offset_us = 0,
    volume = 1.0,
    duration_us = 3333333,
    clip_end_us = 3333333,  -- explicit boundary
}}, mock_cache)

-- Simulate playing state
audio_pb.playing = true
aop_calls = {}
audio_pb.play_burst(500000, 33333)
-- Should bail — no AOP.START call
local found_start = false
for _, call in ipairs(aop_calls) do
    if call == "START" then found_start = true end
end
assert(not found_start, "play_burst should bail when already playing")
audio_pb.playing = false
print("  pass")

print("\nTest 1.4: play_burst produces audio output when stopped")
aop_calls = {}
clear_timers()
audio_pb.play_burst(500000, 33333)

-- Should see: FLUSH, WRITE_F32, START in the aop_calls
local saw_flush = false
local saw_write = false
local saw_start = false
for _, call in ipairs(aop_calls) do
    if call == "FLUSH" then saw_flush = true end
    if call == "WRITE_F32" then saw_write = true end
    if call == "START" then saw_start = true end
end
assert(saw_flush, "play_burst should FLUSH before writing")
assert(saw_write, "play_burst should WRITE_F32 rendered audio")
assert(saw_start, "play_burst should START AOP for burst")
print("  pass")

print("\nTest 1.5: play_burst schedules stop timer")
assert(#timer_callbacks > 0,
    "play_burst should schedule a timer to stop AOP after burst")
print("  pass")

-- Cleanup session
audio_pb.shutdown_session()

--------------------------------------------------------------------------------
-- SECTION 2: playback_controller.play_frame_audio exists
--------------------------------------------------------------------------------
print("\n--- Section 2: playback_controller.play_frame_audio ---")

-- Load fresh playback_controller
package.loaded["core.playback.playback_controller"] = nil
package.loaded["core.playback.source_playback"] = nil
package.loaded["core.playback.timeline_playback"] = nil
package.loaded["core.playback.playback_helpers"] = nil
local pc = require("core.playback.playback_controller")
pc.init(mock_viewer)
pc.set_source(100, 30, 1)

print("\nTest 2.1: play_frame_audio function exists")
assert(type(pc.play_frame_audio) == "function",
    "playback_controller must have play_frame_audio function")
print("  pass")

print("\nTest 2.2: play_frame_audio bails when playing")
pc.state = "playing"
-- Should not error
pc.play_frame_audio(50)
pc.state = "stopped"
print("  pass")

print("\nTest 2.3: play_frame_audio bails when no audio")
-- No audio initialized, should bail gracefully
pc.play_frame_audio(50)
print("  pass")

-- Set up mock audio with play_burst tracking
local burst_calls = {}
local mock_audio_burst = {
    session_initialized = true,
    source_loaded = true,
    has_audio = true,
    playing = false,
    speed = 0,
    media_time_us = 0,
    max_media_time_us = 3333333,
}
function mock_audio_burst.is_ready() return true end
function mock_audio_burst.start() mock_audio_burst.playing = true end
function mock_audio_burst.stop() mock_audio_burst.playing = false end
function mock_audio_burst.set_speed(s) mock_audio_burst.speed = s end
function mock_audio_burst.get_media_time_us() return mock_audio_burst.media_time_us end
function mock_audio_burst.get_time_us() return mock_audio_burst.media_time_us end
function mock_audio_burst.set_max_time(m) mock_audio_burst.max_media_time_us = m end
function mock_audio_burst.set_max_media_time(m) mock_audio_burst.max_media_time_us = m end
function mock_audio_burst.seek(t) mock_audio_burst.media_time_us = t end
function mock_audio_burst.latch(t) end
function mock_audio_burst.play_burst(time_us, duration_us)
    table.insert(burst_calls, {time_us = time_us, duration_us = duration_us})
end

pc.init_audio(mock_audio_burst)

print("\nTest 2.4: play_frame_audio calls play_burst with correct time and duration")
burst_calls = {}
pc.play_frame_audio(30)  -- frame 30 at 30fps = 1000000us
assert(#burst_calls == 1, "play_frame_audio should call play_burst once, got " .. #burst_calls)
assert(burst_calls[1].time_us == 1000000,
    "time_us should be 1000000 for frame 30 at 30fps, got " .. burst_calls[1].time_us)
-- 1.5x frame clamped to [40000,60000]: floor(33333*1.5)=49999 at 30fps
assert(burst_calls[1].duration_us == 49999,
    "duration_us should be 49999 (1.5x frame at 30fps), got " .. burst_calls[1].duration_us)
print("  pass")

--------------------------------------------------------------------------------
-- SECTION 3: seek() same-frame guard prevents redundant decode
--------------------------------------------------------------------------------
print("\n--- Section 3: seek() same-frame dedup ---")

-- Track show_frame calls to count decodes
local show_frame_calls = {}
local mock_viewer2 = {
    show_frame = function(idx) table.insert(show_frame_calls, idx) end,
    has_media = function() return true end,
    get_total_frames = function() return 100 end,
    get_fps = function() return 30 end,
    get_current_frame = function() return 0 end,
}

-- Fresh controller for this section
package.loaded["core.playback.playback_controller"] = nil
package.loaded["core.playback.source_playback"] = nil
package.loaded["core.playback.timeline_playback"] = nil
package.loaded["core.playback.playback_helpers"] = nil
local pc2 = require("core.playback.playback_controller")
pc2.init(mock_viewer2)
pc2.set_source(100, 30, 1)

print("\nTest 3.1: seek() to new frame decodes")
show_frame_calls = {}
pc2.seek(30)
assert(#show_frame_calls == 1,
    "seek(30) should decode once, got " .. #show_frame_calls)
assert(show_frame_calls[1] == 30,
    "should decode frame 30, got " .. show_frame_calls[1])
print("  pass")

print("\nTest 3.2: seek() to same frame skips redundant decode")
show_frame_calls = {}
pc2.seek(30)
assert(#show_frame_calls == 0,
    "seek(30) again should skip decode (same frame), got " .. #show_frame_calls)
print("  pass")

print("\nTest 3.3: seek() to different frame decodes")
show_frame_calls = {}
pc2.seek(31)
assert(#show_frame_calls == 1,
    "seek(31) should decode once, got " .. #show_frame_calls)
print("  pass")

print("\n=== test_frame_step_audio.lua passed ===")
