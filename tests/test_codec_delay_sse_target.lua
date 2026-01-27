--- Test: SSE target adjusts for codec delay on start()
--
-- Bug: AAC codec returns PCM starting at ~20ms even when requesting time=0.
-- SSE target stays at 0, SSE starves forever trying to render unavailable data.
--
-- This test verifies that start() adjusts SSE target to match actual PCM start.
-- Per architecture: SET_TARGET is only called on transport events (start is one).

require("test_env")

print("=== test_codec_delay_sse_target.lua ===")

-- Track SSE calls
local sse_calls = {
    set_target_times = {},  -- list of times passed to SET_TARGET
    current_time = 0,
    pcm_start = 0,
}

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
            return "mock_pcm", frames
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
    EMP = {},
}

package.loaded["core.qt_constants"] = mock_qt_constants

-- Prevent timer recursion
local timer_callbacks = {}
function qt_create_single_shot_timer(ms, callback)
    table.insert(timer_callbacks, callback)
end

-- Mock media_cache with 20ms codec delay
local CODEC_DELAY_US = 20000

local mock_media_cache = {
    get_asset_info = function()
        return {
            has_audio = true,
            audio_sample_rate = 48000,
            audio_channels = 2,
            duration_us = 10000000,
            fps_num = 30,
            fps_den = 1,
        }
    end,
    get_audio_reader = function()
        return { id = "mock_audio_reader" }
    end,
    get_audio_pcm = function(start_us, end_us)
        -- Simulate AAC codec delay: actual data starts at CODEC_DELAY_US
        local actual_start = start_us
        if start_us < CODEC_DELAY_US then
            actual_start = CODEC_DELAY_US
        end
        local frames = math.floor((end_us - actual_start) * 48000 / 1000000)
        return "mock_pcm_ptr", frames, actual_start
    end,
}

-- Fresh load
package.loaded["ui.audio_playback"] = nil
local audio_playback = require("ui.audio_playback")

-- Initialize
local ok = audio_playback.init(mock_media_cache)
assert(ok, "init failed")
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
audio_playback.shutdown()

print("✅ test_codec_delay_sse_target.lua passed")
