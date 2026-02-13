--[[
Test: play_burst respects clip boundary (arrow key jog near edit point)

Bug scenario:
1. Clip ends at timeline time 92.600s
2. User steps to frame at 92.567s using arrow key
3. play_burst(92.567s, 50ms) should play 92.567s - 92.600s (33ms max)
4. BUG: If cached PCM extends to 92.631s, burst plays audio past clip end

This test verifies:
1. _ensure_pcm_cache trims PCM to clip boundary
2. play_burst clamps the audio window to clip_end_us
]]

require("test_env")

local ffi = require("ffi")

--------------------------------------------------------------------------------
-- Mock infrastructure
--------------------------------------------------------------------------------

local mock_aop = {}
local mock_sse = {}
local sse_push_log = {}
local sse_target_log = {}

local SAMPLE_RATE = 48000

local render_log = {}  -- Track render requests

local mock_qt_constants = {
    AOP = {
        OPEN = function() return mock_aop end,
        CLOSE = function() end,
        START = function() end,
        STOP = function() end,
        FLUSH = function() end,
        BUFFERED_FRAMES = function() return 0 end,
        PLAYHEAD_US = function() return 0 end,
        WRITE_F32 = function() return 0 end,
        SAMPLE_RATE = function() return SAMPLE_RATE end,
        CHANNELS = function() return 2 end,
    },
    SSE = {
        CREATE = function() return mock_sse end,
        CLOSE = function() end,
        RESET = function() end,
        PUSH_PCM = function(sse, ptr, frames, start_time, skip_frames, max_frames)
            local actual_frames = max_frames or frames
            local end_time_us = start_time + (actual_frames * 1000000 / SAMPLE_RATE)
            table.insert(sse_push_log, {
                frames = actual_frames,
                start_time_us = start_time,
                end_time_us = end_time_us,
                skip_frames = skip_frames or 0,
            })
        end,
        SET_TARGET = function(sse, time_us, speed, mode)
            table.insert(sse_target_log, {
                time_us = time_us,
            })
        end,
        CURRENT_TIME_US = function() return 0 end,
        RENDER_ALLOC = function(sse, frames)
            table.insert(render_log, {
                requested_frames = frames,
                duration_us = frames * 1000000 / SAMPLE_RATE,
            })
            local buf = ffi.new("float[?]", frames * 2)
            return buf, frames
        end,
    },
}

_G.qt_constants = mock_qt_constants
_G.qt_create_single_shot_timer = function() end
package.loaded["core.qt_constants"] = mock_qt_constants

--------------------------------------------------------------------------------
-- Scenario: Simple clip on timeline
-- Timeline: clip from 65.667s to 92.600s (26.933s duration)
-- Source: 0s to 26.933s (source_in=0, source_out=26.933s)
-- Playhead: 92.567s (33ms before clip end)
--------------------------------------------------------------------------------

local SOURCE_OFFSET_US = 65667000      -- timeline_start - source_in = 65.667s
local CLIP_DURATION_US = 26933000      -- source_out - source_in = 26.933s
local CLIP_END_US = 92600000           -- Clip ends at 92.600s (timeline)
local PLAYHEAD_US = 92567000           -- 33ms before clip end
local BURST_DURATION_US = 50000        -- 50ms burst (would extend 17ms past boundary)

-- The decoder returns MORE than requested due to AAC packet alignment
-- Simulates real behavior where we ask for 26.933s but get 27.0s of audio
local DECODER_OVERSHOOT_US = 67000     -- ~67ms extra (realistic AAC alignment)

--------------------------------------------------------------------------------
-- Mock media_cache that simulates decoder overshoot
--------------------------------------------------------------------------------

local mock_media_cache = {
    ensure_audio_pooled = function(path)
        return { has_audio = true, audio_sample_rate = SAMPLE_RATE }
    end,
    get_audio_pcm_for_path = function(path, src_start, src_end, sample_rate)
        -- Simulate decoder returning MORE frames than requested (AAC alignment)
        -- We're asked for audio from src_start to src_end
        -- But we return audio from src_start to (src_end + overshoot)
        local extended_end = src_end + DECODER_OVERSHOOT_US
        local frames = math.floor((extended_end - src_start) * sample_rate / 1000000)
        frames = math.max(frames, 1)
        local buf = ffi.new("float[?]", frames * 2)
        return buf, frames, src_start
    end,
}

--------------------------------------------------------------------------------
-- Test
--------------------------------------------------------------------------------

print("Test: play_burst at clip boundary")

local audio_playback = require("core.media.audio_playback")

audio_playback.init_session(SAMPLE_RATE, 2)
audio_playback.set_max_time(180000000)

-- Set up source with explicit clip_end_us (as engine provides)
local sources = {{
    path = "/test/clip.mp4",
    source_offset_us = SOURCE_OFFSET_US,
    seek_us = 0,
    speed_ratio = 1.0,
    clip_start_us = SOURCE_OFFSET_US,
    volume = 1.0,
    duration_us = CLIP_DURATION_US,
    clip_end_us = CLIP_END_US,
}}

audio_playback.set_audio_sources(sources, mock_media_cache)
audio_playback.media_time_us = PLAYHEAD_US

print(string.format("  Playhead: %.3fs (timeline)", PLAYHEAD_US / 1000000))
print(string.format("  Clip ends at: %.3fs (timeline)", CLIP_END_US / 1000000))
print(string.format("  Burst duration: %.1fms", BURST_DURATION_US / 1000))

-- Clear logs
sse_push_log = {}
sse_target_log = {}

-- Prime cache
audio_playback._ensure_pcm_cache()

-- Verify cache was trimmed to clip boundary
print(string.format("\n  After _ensure_pcm_cache:"))
print(string.format("    Push count: %d", #sse_push_log))

local cache_exceeded = false
for i, push in ipairs(sse_push_log) do
    print(string.format("    Push %d: %.3fs - %.3fs (%d frames)",
        i, push.start_time_us / 1000000, push.end_time_us / 1000000, push.frames))
    if push.end_time_us > CLIP_END_US + 1000 then
        cache_exceeded = true
        print(string.format("      BUG: Extends past clip_end!"))
    end
end

assert(not cache_exceeded,
    "BUG: _ensure_pcm_cache pushed audio past clip boundary (decoder overshoot not trimmed)")
print("    ✓ Cache correctly trimmed to clip boundary")

-- Now test play_burst
sse_push_log = {}
sse_target_log = {}
render_log = {}

audio_playback.play_burst(PLAYHEAD_US, BURST_DURATION_US)

-- The naive burst would extend from 92.567s to 92.617s (50ms)
-- But clip ends at 92.600s, so max is 92.567s to 92.600s (33ms)
local naive_burst_end = PLAYHEAD_US + BURST_DURATION_US
local expected_max_burst_us = CLIP_END_US - PLAYHEAD_US  -- 33ms
print(string.format("\n  After play_burst:"))
print(string.format("    Naive burst end: %.3fs (if no clamping)", naive_burst_end / 1000000))
print(string.format("    Max allowed end: %.3fs (clip_end)", CLIP_END_US / 1000000))
print(string.format("    Expected clamped burst: %.1fms", expected_max_burst_us / 1000))

-- Verify render request was clamped
assert(#render_log > 0, "Expected at least one RENDER_ALLOC call")
local render = render_log[#render_log]
print(string.format("    Rendered: %.1fms (%d frames)",
    render.duration_us / 1000, render.requested_frames))

-- The rendered duration should be <= the max allowed burst
-- (with some tolerance for frame alignment)
local tolerance_us = 2000  -- 2ms tolerance for frame rounding
if render.duration_us > expected_max_burst_us + tolerance_us then
    print(string.format("    BUG: Rendered %.1fms but should be <= %.1fms!",
        render.duration_us / 1000, expected_max_burst_us / 1000))
    assert(false, string.format(
        "BUG: play_burst rendered %.1fms past clip boundary (max=%.1fms)",
        render.duration_us / 1000, expected_max_burst_us / 1000))
end
print("    ✓ Render duration correctly clamped to clip boundary")

-- Also verify SSE pushes don't exceed boundary
print(string.format("    Push count: %d", #sse_push_log))
local burst_exceeded = false
for i, push in ipairs(sse_push_log) do
    print(string.format("    Push %d: %.3fs - %.3fs (%d frames)",
        i, push.start_time_us / 1000000, push.end_time_us / 1000000, push.frames))
    if push.end_time_us > CLIP_END_US + 1000 then
        burst_exceeded = true
        print(string.format("      BUG: Extends past clip_end!"))
    end
end

assert(not burst_exceeded,
    "BUG: play_burst pushed audio past clip boundary")
print("    ✓ All pushes correctly limited at clip boundary")

audio_playback.shutdown_session()

print("")
print("✅ test_audio_burst_at_clip_boundary.lua passed")
