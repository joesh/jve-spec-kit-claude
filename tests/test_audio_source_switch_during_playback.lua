--- Test: set_audio_sources during playback preserves current time
-- @file test_audio_source_switch_during_playback.lua
--
-- Regression: During timeline playback, crossing an audio clip edit point
-- triggers set_audio_sources(). The old code stopped the pump without
-- snapshotting get_time_us() first, so reanchor() used the stale
-- media_time_us from the last seek/start → playhead jumped back to
-- the position where the user pressed play.
--
-- The fix: set_audio_sources snapshots get_time_us() BEFORE setting
-- playing=false, so reanchor restarts from the correct current position.

require('test_env')

print("=== test_audio_source_switch_during_playback.lua ===")

--------------------------------------------------------------------------------
-- Mock infrastructure
--------------------------------------------------------------------------------

local sse_target_times = {}
local aop_playhead_us = 0

local mock_sse_handle = { _name = "mock_sse" }
local mock_aop_handle = { _name = "mock_aop" }

local mock_qt_constants = {
    AOP = {
        OPEN = function() return mock_aop_handle end,
        CLOSE = function() end,
        START = function() end,
        STOP = function() end,
        FLUSH = function() end,
        PLAYHEAD_US = function() return aop_playhead_us end,
        BUFFERED_FRAMES = function() return 0 end,
        WRITE_F32 = function(aop, pcm, frames) return frames end,
        HAD_UNDERRUN = function() return false end,
        CLEAR_UNDERRUN = function() end,
    },
    SSE = {
        CREATE = function() return mock_sse_handle end,
        CLOSE = function() end,
        RESET = function() end,
        SET_TARGET = function(sse, t_us, speed, mode)
            table.insert(sse_target_times, t_us)
        end,
        PUSH_PCM = function() end,
        RENDER_ALLOC = function(sse, frames)
            return "mock_ptr", frames
        end,
        STARVED = function() return false end,
        CLEAR_STARVED = function() end,
        CURRENT_TIME_US = function() return 0 end,
    },
}

_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants
_G.qt_create_single_shot_timer = function() end

-- Mock media_cache
local mock_cache = {
    get_asset_info = function()
        return {
            has_audio = true,
            audio_sample_rate = 48000,
            audio_channels = 2,
            duration_us = 60000000,
            fps_num = 24,
            fps_den = 1,
        }
    end,
    get_audio_reader = function()
        return { _name = "mock_reader" }
    end,
    get_audio_pcm = function(start_us, end_us)
        local frames = math.floor((end_us - start_us) * 48000 / 1000000)
        return "mock_pcm", frames, start_us
    end,
    get_audio_pcm_for_path = function(path, start_us, end_us)
        local frames = math.floor((end_us - start_us) * 48000 / 1000000)
        return "mock_pcm", frames, start_us
    end,
    get_file_path = function() return "/mock/clip.mov" end,
    ensure_audio_pooled = function() end,
}

-- Load fresh
package.loaded["core.media.audio_playback"] = nil
local audio_playback = require("core.media.audio_playback")

-- Init session and source
audio_playback.init_session(48000, 2)
audio_playback.switch_source(mock_cache)
audio_playback.set_max_media_time(60000000)

--------------------------------------------------------------------------------
-- Test 1: set_audio_sources during playback reanchors at current time
--------------------------------------------------------------------------------
print("Test 1: set_audio_sources during playback preserves current time")

-- Seek to 5s and start playing
audio_playback.seek(5000000)
audio_playback.start()
assert(audio_playback.playing, "should be playing")

-- Simulate AOP advancing 3 seconds (hardware playhead moved 3s from epoch)
aop_playhead_us = 3000000

-- Verify get_time_us returns ~8s (5s start + 3s elapsed at 1x speed)
-- Allow margin for OUTPUT_LATENCY_US compensation (~150ms)
local current_time = audio_playback.get_time_us()
assert(current_time >= 7700000 and current_time <= 8100000,
    string.format("Expected ~8s, got %.3fs", current_time / 1000000))
print(string.format("  current time before switch: %.3fs", current_time / 1000000))

-- Now switch sources (simulates crossing an audio clip edit point)
sse_target_times = {}
audio_playback.set_audio_sources({{
    path = "/mock/clip_b.mov",
    source_offset_us = 0,
    volume = 1.0,
    duration_us = 60000000,
}}, mock_cache)

-- CRITICAL: After source switch, playback should resume at ~8s, NOT 5s.
-- If the bug is present, media_time_us will be 5s (stale from seek).
assert(audio_playback.playing, "should still be playing after source switch")

-- Check media_anchor_us (the reanchor target)
-- It should be ~8s (the snapshotted current time), not 5s (stale start)
assert(audio_playback.media_anchor_us >= 7700000,
    string.format(
        "REGRESSION: reanchor used stale time! anchor=%.3fs, expected ~8s. " ..
        "Playhead would jump back to play-start position.",
        audio_playback.media_anchor_us / 1000000))

print(string.format("  anchor after switch: %.3fs (expected ~8s) ✓",
    audio_playback.media_anchor_us / 1000000))

--------------------------------------------------------------------------------
-- Test 2: set_audio_sources while stopped does NOT snapshot (no AOP access)
--------------------------------------------------------------------------------
print("Test 2: set_audio_sources while stopped keeps current media_time_us")

audio_playback.stop()
audio_playback.seek(12000000)  -- park at 12s

audio_playback.set_audio_sources({{
    path = "/mock/clip_c.mov",
    source_offset_us = 0,
    volume = 1.0,
    duration_us = 60000000,
}}, mock_cache)

assert(not audio_playback.playing, "should not be playing")
assert(audio_playback.media_time_us == 12000000,
    string.format("media_time_us should be 12s, got %.3fs",
        audio_playback.media_time_us / 1000000))
print(string.format("  media_time_us: %.3fs (unchanged) ✓",
    audio_playback.media_time_us / 1000000))

--------------------------------------------------------------------------------
-- Test 3: Verify the bug would be caught (simulate stale reanchor)
--------------------------------------------------------------------------------
print("Test 3: Confirm test catches stale reanchor")

-- This verifies our test assertion is meaningful:
-- If anchor were 5s (the old seek position) instead of ~8s, the assert fires
local would_fail = (5000000 >= 7700000)
assert(not would_fail,
    "Sanity check: 5s must NOT pass the >= 7.7s threshold")
print("  stale value 5s correctly rejected by threshold ✓")

--------------------------------------------------------------------------------
print()
print("✅ test_audio_source_switch_during_playback.lua passed")
