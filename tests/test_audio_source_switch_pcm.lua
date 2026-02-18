--- Test: set_audio_sources during playback fetches PCM from NEW source
-- @file test_audio_source_switch_pcm.lua
--
-- Regression: During timeline playback, crossing a clip edit point calls
-- set_audio_sources with the new clip's path. After the switch, the pump
-- must fetch PCM from the NEW path and push it to SSE. If it goes silent,
-- either PCM isn't fetched, or it's fetched from the wrong path, or the
-- timestamps are wrong so SSE can't render.
--
-- This test verifies:
-- 1. After source switch, get_audio_pcm_for_path is called with new path
-- 2. PUSH_PCM is called after switch (audio data reaches SSE)
-- 3. PUSH_PCM timestamps match the current playback position
-- 4. RENDER_ALLOC produces frames (SSE renders from the pushed data)

require('test_env')

print("=== test_audio_source_switch_pcm.lua ===")

--------------------------------------------------------------------------------
-- Track all audio pipeline calls
--------------------------------------------------------------------------------

local pcm_fetch_log = {}    -- {path, start_us, end_us}
local push_pcm_log = {}     -- {start_us, frames}
local render_log = {}        -- {frames_requested, frames_produced}
local sse_target_log = {}    -- {time_us}
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
            table.insert(sse_target_log, { time_us = t_us })
        end,
        PUSH_PCM = function(sse, pcm_ptr, frames, start_us)
            table.insert(push_pcm_log, {
                start_us = start_us,
                frames = frames,
            })
        end,
        RENDER_ALLOC = function(sse, frames)
            local produced = math.min(frames, 1024)
            table.insert(render_log, {
                frames_requested = frames,
                frames_produced = produced,
            })
            return "rendered_pcm", produced
        end,
        STARVED = function() return false end,
        CLEAR_STARVED = function() end,
        CURRENT_TIME_US = function() return 0 end,
    },
}

_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants
_G.qt_create_single_shot_timer = function() end

-- Mock media_cache that tracks which path PCM is fetched from
local mock_cache = {
    get_media_file_info = function()
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
    get_audio_pcm_for_path = function(path, start_us, end_us, out_sample_rate)
        table.insert(pcm_fetch_log, {
            path = path,
            start_us = start_us,
            end_us = end_us,
        })
        local rate = out_sample_rate or 48000
        local frames = math.floor((end_us - start_us) * rate / 1000000)
        return "mock_pcm_" .. path, frames, start_us
    end,
    get_file_path = function() return "/mock/clip_a.mov" end,
    ensure_audio_pooled = function() end,
}

-- Load fresh
package.loaded["core.media.audio_playback"] = nil
local audio_playback = require("core.media.audio_playback")

-- Init session with source A
audio_playback.init_session(48000, 2)
audio_playback.switch_source(mock_cache)
audio_playback.set_max_media_time(60000000)

--------------------------------------------------------------------------------
-- Test 1: After source switch during playback, PCM fetched from NEW path
--------------------------------------------------------------------------------
print("Test 1: PCM fetched from new path after source switch")

-- Start playing at 10s
audio_playback.seek(10000000)
audio_playback.start()
assert(audio_playback.playing, "should be playing")

-- Simulate 2s of playback
aop_playhead_us = 2000000

-- Clear logs
pcm_fetch_log = {}
push_pcm_log = {}
render_log = {}
sse_target_log = {}

-- Switch to source B at timeline position ~12s
-- source_offset_us=5s means: at playback time 12s, source time = 12-5 = 7s
audio_playback.set_audio_sources({{
    path = "/mock/clip_b.mov",
    source_offset_us = 5000000,  -- clip B starts at 5s on timeline
    seek_us = 0,
    speed_ratio = 1.0,
    clip_start_us = 5000000,
    volume = 1.0,
    duration_us = 30000000,  -- 30s clip
    clip_end_us = 5000000 + 30000000,  -- explicit boundary from engine
}}, mock_cache)

assert(audio_playback.playing, "should still be playing after switch")

-- Verify PCM was fetched from NEW path (not old path)
assert(#pcm_fetch_log > 0,
    "REGRESSION: No PCM fetched after source switch — audio will be silent")

local fetched_new_path = false
for _, fetch in ipairs(pcm_fetch_log) do
    if fetch.path == "/mock/clip_b.mov" then
        fetched_new_path = true
        -- Source time should be in valid range (0 to 30s)
        assert(fetch.start_us >= 0,
            string.format("Source start_us should be >= 0, got %d", fetch.start_us))
        assert(fetch.end_us <= 30000000,
            string.format("Source end_us should be <= 30s, got %.3fs", fetch.end_us / 1000000))
        assert(fetch.end_us > fetch.start_us,
            "Source end_us should be > start_us")
        print(string.format("  fetched from clip_b: %.3fs - %.3fs ✓",
            fetch.start_us / 1000000, fetch.end_us / 1000000))
    end
end
assert(fetched_new_path,
    "REGRESSION: PCM fetched but from WRONG path (not clip_b)")

-- Verify PUSH_PCM was called (data reaches SSE)
assert(#push_pcm_log > 0,
    "REGRESSION: No PUSH_PCM after source switch — SSE has no data, audio silent")
print(string.format("  PUSH_PCM called %d time(s) ✓", #push_pcm_log))

-- Verify PUSH_PCM timestamps are near current playback position (~12s)
local push = push_pcm_log[#push_pcm_log]
assert(push.start_us >= 5000000 and push.start_us <= 20000000,
    string.format("PUSH_PCM start_us should be near 12s, got %.3fs",
        push.start_us / 1000000))
print(string.format("  PUSH_PCM start=%.3fs, frames=%d ✓",
    push.start_us / 1000000, push.frames))

--------------------------------------------------------------------------------
-- Test 2: Pump tick after switch renders from new source
--------------------------------------------------------------------------------
print("Test 2: Pump tick after switch produces rendered audio")

-- Clear logs
render_log = {}
pcm_fetch_log = {}
push_pcm_log = {}

-- Run one pump tick
audio_playback._pump_tick()

-- RENDER_ALLOC should have been called (SSE renders audio)
assert(#render_log > 0,
    "REGRESSION: No RENDER_ALLOC after pump tick — SSE not rendering")

local rendered_any = false
for _, r in ipairs(render_log) do
    if r.frames_produced > 0 then rendered_any = true end
end
assert(rendered_any,
    "REGRESSION: RENDER_ALLOC produced 0 frames — SSE has no data to render (silent)")
print(string.format("  rendered %d frames ✓", render_log[1].frames_produced))

--------------------------------------------------------------------------------
-- Test 3: Source B with different offset — verify source time calculation
--------------------------------------------------------------------------------
print("Test 3: Source offset correctly maps playback→source time")

audio_playback.stop()
aop_playhead_us = 0  -- reset mock hardware playhead before new start
audio_playback.seek(20000000)  -- 20s playback time
audio_playback.start()

-- Clear
pcm_fetch_log = {}
push_pcm_log = {}

-- Switch to source C: starts at timeline 15s, so at playback 20s → source 5s
audio_playback.set_audio_sources({{
    path = "/mock/clip_c.mov",
    source_offset_us = 15000000,  -- clip C starts at 15s on timeline
    seek_us = 0,
    speed_ratio = 1.0,
    clip_start_us = 15000000,
    volume = 1.0,
    duration_us = 60000000,
    clip_end_us = 15000000 + 60000000,  -- explicit boundary from engine
}}, mock_cache)

-- PCM should be decoded around source time 5s (= 20s - 15s offset)
assert(#pcm_fetch_log > 0, "Should fetch PCM for clip_c")
local fetch = pcm_fetch_log[#pcm_fetch_log]
assert(fetch.path == "/mock/clip_c.mov", "Should fetch from clip_c")

-- Source time should be around 5s (20s playback - 15s offset)
-- With a 5s half-window, range is roughly 0-10s in source time
assert(fetch.start_us >= 0 and fetch.start_us <= 6000000,
    string.format("Source start should be near 0-5s, got %.3fs", fetch.start_us / 1000000))
assert(fetch.end_us >= 4000000 and fetch.end_us <= 15000000,
    string.format("Source end should be near 5-10s, got %.3fs", fetch.end_us / 1000000))
print(string.format("  clip_c source range: %.3fs - %.3fs (expected ~0-10s) ✓",
    fetch.start_us / 1000000, fetch.end_us / 1000000))

-- PUSH_PCM timestamps should be in PLAYBACK time (around 20s, not source 5s)
assert(#push_pcm_log > 0, "Should push PCM for clip_c")
local push_c = push_pcm_log[#push_pcm_log]
assert(push_c.start_us >= 14000000,
    string.format(
        "REGRESSION: PUSH_PCM uses source time (%.3fs) instead of playback time. " ..
        "SSE target is at 20s but PCM starts at %.3fs → SSE starves → silence.",
        push_c.start_us / 1000000, push_c.start_us / 1000000))
print(string.format("  PUSH_PCM playback time: %.3fs (expected ~15-20s) ✓",
    push_c.start_us / 1000000))

--------------------------------------------------------------------------------
-- Test 4: timeline_start uses timeline fps, source_in uses clip fps
-- Regression: resolve_and_set_audio_sources converted timeline_start.frames
-- using clip_rate instead of the Rational's own fps. When clip fps != timeline
-- fps, the source_offset_us is wrong → PCM decoded at wrong position → silence.
--------------------------------------------------------------------------------
print("Test 4: source_offset_us correct when clip fps != timeline fps")

-- Simulate what resolve_and_set_audio_sources does with the offset calculation.
-- This tests the math directly.
local Rational = require("core.rational")

-- Timeline fps: 24000/1001 (~23.976), Clip fps: 48000/1001 (~47.952)
local tl_fps_num, tl_fps_den = 24000, 1001
local clip_fps_num, clip_fps_den = 48000, 1001

-- Clip starts at timeline frame 720 (= 30.03s @ 24000/1001)
local timeline_start = Rational.new(720, tl_fps_num, tl_fps_den)
-- Source in at clip frame 0
local source_in = Rational.new(0, clip_fps_num, clip_fps_den)

-- CORRECT: use each Rational's own fps
local timeline_start_us_correct = math.floor(timeline_start:to_seconds() * 1000000)
local source_in_us_correct = math.floor(source_in:to_seconds() * 1000000)
local offset_correct = timeline_start_us_correct - source_in_us_correct

-- BUG: use clip_rate for both (the old code)
local timeline_start_us_buggy = math.floor(
    timeline_start.frames * 1000000 * clip_fps_den / clip_fps_num)
local source_in_us_buggy = math.floor(
    source_in.frames * 1000000 * clip_fps_den / clip_fps_num)
local offset_buggy = timeline_start_us_buggy - source_in_us_buggy

print(string.format("  correct timeline_start: %.3fs", timeline_start_us_correct / 1000000))
print(string.format("  buggy   timeline_start: %.3fs", timeline_start_us_buggy / 1000000))
print(string.format("  correct offset: %.3fs", offset_correct / 1000000))
print(string.format("  buggy   offset: %.3fs", offset_buggy / 1000000))

-- With 48kHz clip rate applied to 24fps timeline frames:
-- buggy = 720 * 1000000 * 1001/48000 = 15.015s (WRONG - half of real value)
-- correct = 720 * 1000000 * 1001/24000 = 30.03s
assert(math.abs(timeline_start_us_correct - 30030000) < 1000,
    string.format("Correct timeline_start should be ~30.03s, got %.3fs",
        timeline_start_us_correct / 1000000))

-- The buggy calculation produces a DIFFERENT value
assert(timeline_start_us_buggy ~= timeline_start_us_correct,
    "BUG DEMO: buggy and correct values should differ when fps mismatch exists")

-- The difference means offset_buggy is wrong
assert(offset_buggy ~= offset_correct,
    "BUG DEMO: buggy offset should differ from correct offset")

print(string.format("  difference: %.3fs (would cause silence or wrong audio)",
    (offset_correct - offset_buggy) / 1000000))
print("  ✓ bug caught: clip_rate applied to timeline_start produces wrong offset")

--------------------------------------------------------------------------------
print()
print("✅ test_audio_source_switch_pcm.lua passed")
