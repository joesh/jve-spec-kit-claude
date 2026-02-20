require('test_env')

-- Mock qt_constants
local mock_qt_constants = {
    EMP = {
        MEDIA_FILE_OPEN = function() return nil, { msg = "mock" } end,
        MEDIA_FILE_INFO = function() return nil end,
        MEDIA_FILE_CLOSE = function() end,
        READER_CREATE = function() return nil, { msg = "mock" } end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil, { msg = "mock" } end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
        SET_DECODE_MODE = function() end,
        TMB_GET_TRACK_AUDIO = function() return nil end,
        TMB_SET_AUDIO_MIX_PARAMS = function() end,
        TMB_GET_MIXED_AUDIO = function() return nil end,
        PCM_INFO = function() return { frames = 0, start_time_us = 0 } end,
        PCM_DATA_PTR = function() return nil end,
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
    get_media_file_info = function() return { fps_num = 30, fps_den = 1, has_audio = true, audio_sample_rate = 48000, duration_us = 3333333 } end,
    get_file_path = function() return "/mock/media.mov" end,
    ensure_audio_pooled = function() return { has_audio = true, audio_sample_rate = 48000, duration_us = 3333333 } end,
    get_audio_pcm_for_path = function(path, start_us, end_us, sr) return "mock_pcm_ptr", 1024, start_us end,
}

-- Timer infrastructure
_G.qt_create_single_shot_timer = function() end

-- Track SSE.SET_TARGET calls to observe quality mode
local set_target_calls = {}
mock_qt_constants.SSE.SET_TARGET = function(sse, t_us, speed, quality_mode)
    table.insert(set_target_calls, {
        t_us = t_us,
        speed = speed,
        quality_mode = quality_mode,
    })
end

print("=== Test slow-motion uses no pitch correction (varispeed) ===")

-- Load audio_playback fresh
package.loaded["core.media.audio_playback"] = nil
local audio_pb = require("core.media.audio_playback")

local Q1 = audio_pb.Q1
local Q3_DECIMATE = audio_pb.Q3_DECIMATE

-- Init session
audio_pb.init_session(48000, 2)
audio_pb.set_max_time(3333333)

-- Set TMB mix (replaces legacy set_audio_sources)
audio_pb.apply_mix("mock_tmb", {
    { track_index = 1, volume = 1.0, muted = false, soloed = false },
}, 0)

--------------------------------------------------------------------------------
-- Test 1: 0.5x speed selects Q3_DECIMATE (varispeed, no pitch correction)
--------------------------------------------------------------------------------
print("\nTest 1: 0.5x speed uses Q3_DECIMATE (varispeed)")
set_target_calls = {}
audio_pb.set_speed(0.5)
assert(audio_pb.quality_mode == Q3_DECIMATE,
    string.format("0.5x should select Q3_DECIMATE (%d), got %d",
        Q3_DECIMATE, audio_pb.quality_mode))
print("  pass")

--------------------------------------------------------------------------------
-- Test 2: -0.5x (reverse slow) also selects Q3_DECIMATE
--------------------------------------------------------------------------------
print("\nTest 2: -0.5x speed uses Q3_DECIMATE")
audio_pb.set_speed(-0.5)
assert(audio_pb.quality_mode == Q3_DECIMATE,
    string.format("-0.5x should select Q3_DECIMATE (%d), got %d",
        Q3_DECIMATE, audio_pb.quality_mode))
print("  pass")

--------------------------------------------------------------------------------
-- Test 3: 1.0x speed still uses Q1 (pitch-corrected)
--------------------------------------------------------------------------------
print("\nTest 3: 1.0x speed stays Q1")
audio_pb.set_speed(1.0)
assert(audio_pb.quality_mode == Q1,
    string.format("1.0x should select Q1 (%d), got %d",
        Q1, audio_pb.quality_mode))
print("  pass")

--------------------------------------------------------------------------------
-- Test 4: 2.0x speed still uses Q1
--------------------------------------------------------------------------------
print("\nTest 4: 2.0x speed stays Q1")
audio_pb.set_speed(2.0)
assert(audio_pb.quality_mode == Q1,
    string.format("2.0x should select Q1 (%d), got %d",
        Q1, audio_pb.quality_mode))
print("  pass")

--------------------------------------------------------------------------------
-- Test 5: 8.0x speed uses Q3_DECIMATE (existing behavior)
--------------------------------------------------------------------------------
print("\nTest 5: 8.0x speed uses Q3_DECIMATE (existing)")
audio_pb.set_speed(8.0)
assert(audio_pb.quality_mode == Q3_DECIMATE,
    string.format("8.0x should select Q3_DECIMATE (%d), got %d",
        Q3_DECIMATE, audio_pb.quality_mode))
print("  pass")

--------------------------------------------------------------------------------
-- Test 6: 0.5x while playing triggers reanchor with Q3_DECIMATE
--------------------------------------------------------------------------------
print("\nTest 6: 0.5x while playing reanchors with Q3_DECIMATE")
-- Start playback at 1x first
audio_pb.set_speed(1.0)
audio_pb.start()
assert(audio_pb.playing, "Should be playing")

set_target_calls = {}
audio_pb.set_speed(0.5)

-- Should have reanchored (mode changed from Q1 to Q3_DECIMATE)
assert(#set_target_calls > 0,
    "Mode change during playback should trigger reanchor")
local last_call = set_target_calls[#set_target_calls]
assert(last_call.quality_mode == Q3_DECIMATE,
    string.format("Reanchor should use Q3_DECIMATE (%d), got %d",
        Q3_DECIMATE, last_call.quality_mode))
assert(last_call.speed == 0.5,
    string.format("Reanchor speed should be 0.5, got %s", tostring(last_call.speed)))
print("  pass")

audio_pb.stop()

--------------------------------------------------------------------------------
-- Test 7: 0.15x uses Q2 (extreme slomo, still pitch-corrected below 0.25x)
-- Actually, let's verify the boundary: < 0.25x should NOT be varispeed
-- because at extreme slow speeds, varispeed would be almost silent.
-- Q2 pitch-correction is better there.
--------------------------------------------------------------------------------
print("\nTest 7: 0.15x uses Q2 (extreme slomo, not varispeed)")
audio_pb.set_speed(0.15)
local Q2 = audio_pb.Q2
assert(audio_pb.quality_mode == Q2,
    string.format("0.15x should select Q2 (%d), got %d",
        Q2, audio_pb.quality_mode))
print("  pass")

audio_pb.shutdown_session()

print("\n=== test_slomo_no_pitch_correction.lua passed ===")
