--[[
Test: Audio prefetch fetch range must be limited by clip end boundary

Verifies that _ensure_pcm_cache() respects the explicit clip_end_us from engine.
The engine computes: clip_end_us = timeline_start + (source_out - source_in)
This boundary is passed to audio_playback, which uses it directly.
]]

require("test_env")

local HALF_WINDOW_US = 5000000  -- 5 seconds

--------------------------------------------------------------------------------
-- Mock infrastructure
--------------------------------------------------------------------------------

local mock_aop = {}
local mock_sse = {}
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
        SAMPLE_RATE = function() return 48000 end,
        CHANNELS = function() return 2 end,
    },
    SSE = {
        CREATE = function() return mock_sse end,
        CLOSE = function() end,
        RESET = function() end,
        PUSH_PCM = function() end,
        SET_PLAYHEAD_US = function() end,
    },
}

_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

local audio_playback = require("core.media.audio_playback")

--------------------------------------------------------------------------------
-- Test setup
--------------------------------------------------------------------------------

local fetch_log = {}

local mock_media_cache = {
    ensure_audio_pooled = function(path)
        return {
            has_audio = true,
            audio_sample_rate = 48000,
            duration_us = 60000000,
        }
    end,
    get_audio_pcm_for_path = function(path, src_start, src_end, sample_rate)
        table.insert(fetch_log, { src_start = src_start, src_end = src_end })
        local ffi = require("ffi")
        local frames = math.floor((src_end - src_start) * sample_rate / 1000000)
        frames = math.max(frames, 1)
        local buf = ffi.new("float[?]", frames * 2)
        return buf, frames, src_start
    end,
}

--------------------------------------------------------------------------------
-- Scenario parameters (from real bug)
--------------------------------------------------------------------------------

local CLIP_END_US = 92600000         -- 92.6s (edit point)
local PLAYHEAD_US = 91467000         -- 91.467s
local SOURCE_OFFSET_US = 70667000    -- source_offset
local MAX_MEDIA_US = 180000000       -- 3 minute timeline

-- For this test: clip ends at 110.667s timeline (offset + 40s duration)
local CLIP_DURATION_US = 40000000
local sources = {{
    path = "/test/22D-3.mp4",
    source_offset_us = SOURCE_OFFSET_US,
    volume = 1.0,
    duration_us = CLIP_DURATION_US,
    clip_end_us = SOURCE_OFFSET_US + CLIP_DURATION_US,  -- 110.667s explicit from engine
}}

--------------------------------------------------------------------------------
-- Test: Clip end derived from source data (no external parameter needed)
--------------------------------------------------------------------------------

print("Test: Fetch limited by source-derived clip end")

audio_playback.init_session(48000, 2)
audio_playback.set_max_time(MAX_MEDIA_US)

-- Set sources (no clip_end_us parameter - limit is computed from source data)
audio_playback.set_audio_sources(sources, mock_media_cache)
audio_playback.media_time_us = PLAYHEAD_US

fetch_log = {}
audio_playback._ensure_pcm_cache()

assert(#fetch_log > 0, "Expected fetch")

-- Clip end in source time = duration_us (since we fetch relative to source)
-- The source has duration_us = 40s, but the clip ends at 92.6s in timeline.
-- Timeline clip end = source_offset + duration = 70.667 + 40 = 110.667s
-- BUT what matters for THIS clip is:
--   playhead at 91.467s, clip ends at 92.6s (SOURCE_OFFSET + clip_duration)
-- Actually wait - let's recalculate:
--   clip ends at CLIP_END_US = 92.6s timeline
--   in source time: 92.6 - 70.667 = 21.933s
-- The source.duration_us = 40s but the CLIP is only until 21.933s in source!
--
-- Hmm, the test setup is wrong. The source's duration_us should be the clip's
-- source duration, not the full media duration. Let me reconsider...
--
-- Actually, the source was set up with:
--   duration_us = 40000000 (40s) - this is wrong for this scenario
--
-- For this test, the clip ends at timeline 92.6s with offset 70.667s:
--   clip_end_in_source = 92.6 - 70.667 = 21.933s
-- So duration_us should be 21.933s for the clip to end there!

-- The current source has duration_us = 40s, so clip_end = 70.667 + 40 = 110.667s
-- With playhead at 91.467s and half_window = 5s:
--   pb_end = min(110.667, 91.467 + 5) = 96.467s
--   src_end = 96.467 - 70.667 = 25.8s
-- That's correct behavior for duration_us = 40s!
--
-- To test the REAL scenario (clip ends at 92.6s), we need duration_us = 21.933s

local fetch_src_end = fetch_log[1].src_end
local expected_clip_end_timeline = SOURCE_OFFSET_US + sources[1].duration_us  -- 110.667s
local expected_src_end = math.min(sources[1].duration_us,
    PLAYHEAD_US + HALF_WINDOW_US - SOURCE_OFFSET_US)

print(string.format("  src_end=%.3fs, expected<=%.3fs (clip ends at timeline %.3fs)",
    fetch_src_end / 1000000, expected_src_end / 1000000,
    expected_clip_end_timeline / 1000000))

-- Verify fetch respects the computed clip end
assert(fetch_src_end <= expected_src_end + 100000,
    string.format("Fetch exceeds expected! src_end=%.3fs > expected=%.3fs",
        fetch_src_end / 1000000, expected_src_end / 1000000))
print("  ✓ Fetch correctly limited by source-derived clip end")

audio_playback.shutdown_session()

--------------------------------------------------------------------------------
-- Test 2: Clip with short duration (edit point before 5s prefetch window)
--------------------------------------------------------------------------------

print("Test 2: Short clip - fetch limited before prefetch window")

package.loaded["core.media.audio_playback"] = nil
audio_playback = require("core.media.audio_playback")

-- Set up a clip that ends at 92.6s in timeline (21.933s in source)
local SHORT_CLIP_DURATION_US = CLIP_END_US - SOURCE_OFFSET_US  -- 21.933s
local short_sources = {{
    path = "/test/22D-3.mp4",
    source_offset_us = SOURCE_OFFSET_US,
    volume = 1.0,
    duration_us = SHORT_CLIP_DURATION_US,  -- 21.933s
    clip_end_us = CLIP_END_US,  -- 92.6s explicit from engine
}}

audio_playback.init_session(48000, 2)
audio_playback.set_max_time(MAX_MEDIA_US)
audio_playback.set_audio_sources(short_sources, mock_media_cache)
audio_playback.media_time_us = PLAYHEAD_US

fetch_log = {}
audio_playback._ensure_pcm_cache()

assert(#fetch_log > 0, "Expected fetch")
local fetch_src_end2 = fetch_log[1].src_end
local clip_src_end = CLIP_END_US - SOURCE_OFFSET_US  -- 21.933s

print(string.format("  src_end=%.3fs, clip_end_in_src=%.3fs",
    fetch_src_end2 / 1000000, clip_src_end / 1000000))

-- Fetch should NOT extend past the clip end (the bug was it would reach 25.8s)
assert(fetch_src_end2 <= clip_src_end + 100000,
    string.format("BUG: Fetch extends past clip! src_end=%.3fs > clip_end=%.3fs",
        fetch_src_end2 / 1000000, clip_src_end / 1000000))
print("  ✓ Fetch limited at clip boundary (no audio bleeding)")

audio_playback.shutdown_session()

print("✅ test_audio_prefetch_clip_boundary.lua passed")
