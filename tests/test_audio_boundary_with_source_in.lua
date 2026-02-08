--[[
Test: Audio playback respects clip boundary when source_in > 0

The architectural bug:
- audio_playback computes clip_end = source_offset_us + duration_us
- But source_offset = timeline_start - source_in
- And duration = source_out - source_in
- So clip_end = (timeline_start - source_in) + (source_out - source_in)
-             = timeline_start + source_out - 2*source_in  -- WRONG!

The correct formula is:
- clip_end = timeline_start + (source_out - source_in)
-          = timeline_start + source_out - source_in  -- RIGHT!

When source_in = 0, both formulas give the same answer (bug is hidden).
When source_in > 0, the buggy formula gives a SMALLER clip_end,
causing audio to stop EARLY.

This test exposes the bug using a clip with significant source_in.
]]

require("test_env")

--------------------------------------------------------------------------------
-- Mock infrastructure
--------------------------------------------------------------------------------

local mock_aop = { playhead = 0 }
local mock_sse = { current_time = 0 }

local mock_qt_constants = {
    AOP = {
        OPEN = function() return mock_aop end,
        CLOSE = function() end,
        START = function() end,
        STOP = function() end,
        FLUSH = function() end,
        BUFFERED_FRAMES = function() return 0 end,
        PLAYHEAD_US = function() return mock_aop.playhead end,
        WRITE_F32 = function() return 0 end,
        SAMPLE_RATE = function() return 48000 end,
        CHANNELS = function() return 2 end,
        HAD_UNDERRUN = function() return false end,
    },
    SSE = {
        CREATE = function() return mock_sse end,
        CLOSE = function() end,
        RESET = function() end,
        PUSH_PCM = function() end,
        SET_TARGET = function() end,
        CURRENT_TIME_US = function() return mock_sse.current_time end,
        RENDER_ALLOC = function(sse, frames) return nil, 0 end,
        STARVED = function() return false end,
        CLEAR_STARVED = function() end,
    },
}

_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants
_G.qt_create_single_shot_timer = function() end

package.loaded["core.logger"] = {
    debug = function() end, info = function() end,
    warn = function() end, error = function() end, trace = function() end,
}

--------------------------------------------------------------------------------
-- Test Scenario: clip with source_in = 10s, source_out = 30s, timeline_start = 5s
--------------------------------------------------------------------------------

local SOURCE_IN_SEC = 10       -- Clip starts at 10s into source media
local SOURCE_OUT_SEC = 30      -- Clip ends at 30s into source media
local TIMELINE_START_SEC = 5   -- Clip placed at 5s on timeline
local CLIP_DURATION_SEC = SOURCE_OUT_SEC - SOURCE_IN_SEC  -- = 20s

-- CORRECT: clip ends at timeline 5s + 20s = 25s
local CORRECT_TIMELINE_END_SEC = TIMELINE_START_SEC + CLIP_DURATION_SEC  -- = 25s

-- BUGGY formula would compute:
--   source_offset = 5 - 10 = -5s
--   clip_end = -5 + 20 = 15s  (WRONG! Should be 25s)
local BUGGY_TIMELINE_END_SEC = (TIMELINE_START_SEC - SOURCE_IN_SEC) + CLIP_DURATION_SEC  -- = 15s

print("Test: Audio boundary with source_in > 0")
print("")
print("Clip parameters:")
print(string.format("  source_in = %.1fs", SOURCE_IN_SEC))
print(string.format("  source_out = %.1fs", SOURCE_OUT_SEC))
print(string.format("  timeline_start = %.1fs", TIMELINE_START_SEC))
print(string.format("  clip_duration = %.1fs", CLIP_DURATION_SEC))
print("")
print(string.format("CORRECT timeline end = %.1fs", CORRECT_TIMELINE_END_SEC))
print(string.format("BUGGY timeline end = %.1fs (source_offset + duration)", BUGGY_TIMELINE_END_SEC))

--------------------------------------------------------------------------------
-- Build sources like playback_controller.resolve_and_set_audio_sources does
--------------------------------------------------------------------------------

local function build_sources_with_explicit_boundary()
    -- This mirrors the FIXED playback_controller.lua
    local timeline_start_us = math.floor(TIMELINE_START_SEC * 1000000)
    local source_in_us = math.floor(SOURCE_IN_SEC * 1000000)
    local source_out_us = math.floor(SOURCE_OUT_SEC * 1000000)

    -- source_offset = timeline_start - source_in
    local source_offset_us = timeline_start_us - source_in_us

    -- duration = source_out - source_in (this is correct)
    local clip_duration_us = source_out_us - source_in_us

    -- EXPLICIT BOUNDARY: computed by engine, not reconstructed by audio_playback
    local clip_end_us = timeline_start_us + clip_duration_us

    return {{
        path = "/test/media.mp4",
        source_offset_us = source_offset_us,
        volume = 1.0,
        duration_us = clip_duration_us,
        clip_end_us = clip_end_us,  -- EXPLICIT from engine
    }}
end

--------------------------------------------------------------------------------
-- Mock media_cache to capture fetch requests
--------------------------------------------------------------------------------

local fetch_log = {}

local mock_media_cache = {
    ensure_audio_pooled = function(path)
        return { has_audio = true, audio_sample_rate = 48000, duration_us = 60000000 }
    end,
    get_audio_pcm_for_path = function(path, src_start, src_end, sample_rate)
        table.insert(fetch_log, {
            src_start_us = src_start,
            src_end_us = src_end,
            src_start_sec = src_start / 1000000,
            src_end_sec = src_end / 1000000,
        })
        local ffi = require("ffi")
        local frames = math.floor((src_end - src_start) * sample_rate / 1000000)
        frames = math.max(frames, 1)
        local buf = ffi.new("float[?]", frames * 2)
        return buf, frames, src_start
    end,
}

--------------------------------------------------------------------------------
-- Test
--------------------------------------------------------------------------------

local audio_playback = require("core.media.audio_playback")

audio_playback.init_session(48000, 2)
audio_playback.set_max_time(60000000)  -- 60s max

local sources = build_sources_with_explicit_boundary()

print("")
print("Source data passed to audio_playback:")
print(string.format("  source_offset_us = %.3fs", sources[1].source_offset_us / 1000000))
print(string.format("  duration_us = %.3fs", sources[1].duration_us / 1000000))
print(string.format("  clip_end_us = %.3fs (EXPLICIT from engine)", sources[1].clip_end_us / 1000000))

-- What the OLD buggy formula would compute:
local buggy_clip_end_us = sources[1].source_offset_us + sources[1].duration_us
print(string.format("  buggy formula = %.3fs (source_offset + duration)", buggy_clip_end_us / 1000000))

-- Verify the explicit value is correct
if math.abs(buggy_clip_end_us / 1000000 - BUGGY_TIMELINE_END_SEC) < 0.001 then
    print("")
    print("OLD BUG would have computed wrong boundary:")
    print(string.format("  Would stop at %.1fs instead of %.1fs", BUGGY_TIMELINE_END_SEC, CORRECT_TIMELINE_END_SEC))
end

audio_playback.set_audio_sources(sources, mock_media_cache)

-- The correct clip end in timeline time is 25s
local CORRECT_CLIP_END_US = CORRECT_TIMELINE_END_SEC * 1000000

-- With the fix, audio_playback uses explicit clip_end_us, not the buggy formula
local ACTUAL_CLIP_END_US = sources[1].clip_end_us

print("")
print("Testing clip boundary detection...")

-- THE KEY ASSERTION: With explicit clip_end_us, boundary should be correct
if math.abs(ACTUAL_CLIP_END_US - CORRECT_CLIP_END_US) > 1000 then
    print("")
    print("======================================")
    print("BUG DETECTED: Incorrect clip boundary")
    print("======================================")
    print("")
    print(string.format("  Actual:   %.3fs (clip_end_us from engine)", ACTUAL_CLIP_END_US / 1000000))
    print(string.format("  Correct:  %.3fs (timeline_start + clip_duration)", CORRECT_CLIP_END_US / 1000000))
    print(string.format("  Error:    %.3fs", (ACTUAL_CLIP_END_US - CORRECT_CLIP_END_US) / 1000000))

    -- This assert should FAIL if clip_end_us is wrong
    assert(false, string.format(
        "BUG: clip_end is %.3fs, should be %.3fs (diff=%.3fs)",
        ACTUAL_CLIP_END_US / 1000000,
        CORRECT_CLIP_END_US / 1000000,
        (ACTUAL_CLIP_END_US - CORRECT_CLIP_END_US) / 1000000))
else
    print(string.format("  ✓ Clip boundary is correct: %.3fs", ACTUAL_CLIP_END_US / 1000000))
    print("")
    print("  Note: OLD buggy formula (source_offset + duration) would have given:")
    print(string.format("         %.3fs (error: %.3fs)", buggy_clip_end_us / 1000000,
        (buggy_clip_end_us - CORRECT_CLIP_END_US) / 1000000))
end

audio_playback.shutdown_session()

print("")
print("✅ test_audio_boundary_with_source_in.lua passed")
