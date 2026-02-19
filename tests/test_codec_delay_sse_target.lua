--- Test: SSE target adjusts for codec delay on start()
--
-- Bug: AAC codec returns PCM starting at ~20ms even when requesting time=0.
-- SSE target stays at 0, SSE starves forever trying to render unavailable data.
--
-- This test verifies that start() adjusts SSE target to match actual PCM start.
-- Per architecture: SET_TARGET is only called on transport events (start is one).
--
-- TMB path: decode_mix_and_send_to_sse() calls TMB_GET_TRACK_AUDIO which returns
-- PcmChunk with start_time_us = CODEC_DELAY_US. advance_sse_past_codec_delay()
-- detects SSE target < actual PCM start and advances SSE.

require("test_env")

local ffi = require("ffi")

print("=== test_codec_delay_sse_target.lua ===")

-- Track SSE calls
local sse_calls = {
    set_target_times = {},  -- list of times passed to SET_TARGET
    current_time = 0,
    pcm_start = 0,
}

-- Mock media_cache with 20ms codec delay
local CODEC_DELAY_US = 20000

-- Pre-allocate FFI buffer for mock PCM data (stereo, ~5s at 48kHz)
local mock_pcm_buf = ffi.new("float[?]", 480000)

-- Mock qt_constants with call tracking
local mock_qt_constants = {
    SSE = {
        CREATE = function(opts) return { id = "mock_sse" } end,
        RESET = function(sse)
            sse_calls.current_time = 0
        end,
        SET_TARGET = function(sse, time_us, speed, quality)
            sse_calls.current_time = time_us
            table.insert(sse_calls.set_target_times, time_us)
        end,
        CURRENT_TIME_US = function(sse)
            return sse_calls.current_time
        end,
        PUSH_PCM = function(sse, ptr, frames, start_us)
            sse_calls.pcm_start = start_us
        end,
        RENDER_ALLOC = function(sse, frames)
            return mock_pcm_buf, frames
        end,
        STARVED = function(sse)
            -- Starved if trying to render before PCM starts
            return sse_calls.current_time < sse_calls.pcm_start
        end,
        CLEAR_STARVED = function(sse) end,
        CLOSE = function(sse) end,
    },
    AOP = {
        OPEN = function(rate, ch, buf_ms) return { id = "mock_aop" } end,
        START = function(aop) end,
        STOP = function(aop) end,
        FLUSH = function(aop) end,
        PLAYHEAD_US = function(aop) return 0 end,
        BUFFERED_FRAMES = function(aop) return 4800 end,
        WRITE_F32 = function(aop, pcm, frames) end,
        HAD_UNDERRUN = function(aop) return false end,
        CLEAR_UNDERRUN = function(aop) end,
        CLOSE = function(aop) end,
    },
    EMP = {
        -- Simulate AAC codec delay: when requesting audio starting before
        -- CODEC_DELAY_US, the actual PCM starts at CODEC_DELAY_US.
        TMB_GET_TRACK_AUDIO = function(tmb, track_index, t0, t1, sr, ch)
            local actual_start = t0
            if t0 < CODEC_DELAY_US then
                actual_start = CODEC_DELAY_US
            end
            local duration_us = t1 - actual_start
            if duration_us <= 0 then return nil end
            local frames = math.floor(duration_us * sr / 1000000)
            return {
                _start_us = actual_start,
                _frames = frames,
                _channels = ch or 2,
            }
        end,
        PCM_INFO = function(pcm)
            return { frames = pcm._frames, start_time_us = pcm._start_us }
        end,
        PCM_DATA_PTR = function(pcm)
            return mock_pcm_buf
        end,
        PCM_RELEASE = function(pcm) end,
    },
}

package.loaded["core.qt_constants"] = mock_qt_constants

-- Prevent timer recursion
local timer_callbacks = {}
function qt_create_single_shot_timer(ms, callback)
    table.insert(timer_callbacks, callback)
end

-- Fresh load
package.loaded["core.media.audio_playback"] = nil
local audio_playback = require("core.media.audio_playback")

-- Initialize session + TMB mix
audio_playback.init_session(48000, 2)
audio_playback.apply_mix("mock_tmb", {
    { track_index = 1, volume = 1.0, muted = false, soloed = false },
}, 0)
audio_playback.set_max_media_time(10000000)

-- Seek to time 0 (where codec delay will cause gap)
audio_playback.seek(0)

-- Clear tracking
sse_calls.set_target_times = {}

-- START PLAYBACK - this is the transport event being tested
audio_playback.start()

-- THE ACTUAL TEST:
-- After start(), SSE target should be at actual PCM start (20ms), not 0
local final_sse_target = sse_calls.current_time

print(string.format("  PCM starts at: %d us (%.1f ms)", CODEC_DELAY_US, CODEC_DELAY_US/1000))
print(string.format("  Final SSE target: %d us (%.1f ms)", final_sse_target, final_sse_target/1000))
print(string.format("  SET_TARGET calls: %s", table.concat(sse_calls.set_target_times, ", ")))

-- This assertion should FAIL without the fix
assert(final_sse_target >= CODEC_DELAY_US,
    string.format("FAIL: SSE target is %d us but PCM starts at %d us - SSE will starve!",
        final_sse_target, CODEC_DELAY_US))

-- Cleanup
audio_playback.shutdown_session()

print("✅ test_codec_delay_sse_target.lua passed")
