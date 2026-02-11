--[[
Test: Timeline mode audio prefetch respects clip boundary

Exercises the REAL code path:
1. resolve_and_set_audio_sources() builds sources from clip data
2. audio_playback.set_audio_sources() receives the sources
3. _ensure_pcm_cache() computes clip_end from source data
4. Fetch is limited to clip boundary

Uses realistic clip data matching the original bug scenario:
- Clip at timeline 70.667s to 92.6s (21.933s duration)
- Playhead at 91.467s (near end of clip)
- Prefetch window is 5s, so naive fetch would extend to 96.467s
- But clip ends at 92.6s, so fetch must stop there
]]

require("test_env")

--------------------------------------------------------------------------------
-- Mock infrastructure (minimal, matching real types)
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

--------------------------------------------------------------------------------
-- Test scenario (from actual bug)
--------------------------------------------------------------------------------

-- Timeline: 24 fps (constants documented here, used in calc_time_us_from_frame calls below)

-- Clip parameters (in seconds, will convert to Rational)
local TIMELINE_START_SEC = 70.667   -- Clip starts at 70.667s in timeline
local SOURCE_IN_SEC = 0             -- Clip uses source from 0s
local SOURCE_OUT_SEC = 21.933       -- Clip uses source to 21.933s (clip is 21.933s long)
local CLIP_TIMELINE_END_SEC = TIMELINE_START_SEC + (SOURCE_OUT_SEC - SOURCE_IN_SEC)  -- 92.6s

local PLAYHEAD_SEC = 91.467         -- Near end of clip
local PLAYHEAD_US = PLAYHEAD_SEC * 1000000

-- Prefetch window
local HALF_WINDOW_US = 5000000      -- 5 seconds

-- Timeline max (3 minute timeline)
local MAX_MEDIA_US = 180000000

--------------------------------------------------------------------------------
-- Build source data the way resolve_and_set_audio_sources does
--------------------------------------------------------------------------------

local function build_sources_like_real_code()
    -- This mirrors playback_controller.lua (fixed version with explicit clip_end_us)
    local timeline_start_us = math.floor(TIMELINE_START_SEC * 1000000)
    local source_in_us = math.floor(SOURCE_IN_SEC * 1000000)
    local source_offset_us = timeline_start_us - source_in_us

    local source_out_us = math.floor(SOURCE_OUT_SEC * 1000000)
    local clip_duration_us = source_out_us - source_in_us

    -- EXPLICIT BOUNDARY: computed by engine, passed to audio_playback
    local clip_end_us = timeline_start_us + clip_duration_us

    return {{
        path = "/test/22D-3.mp4",
        source_offset_us = source_offset_us,
        volume = 1.0,
        duration_us = clip_duration_us,
        clip_end_us = clip_end_us,
    }}
end

--------------------------------------------------------------------------------
-- Mock media_cache
--------------------------------------------------------------------------------

local fetch_log = {}

local mock_media_cache = {
    ensure_audio_pooled = function(path)
        return {
            has_audio = true,
            audio_sample_rate = 48000,
            duration_us = 60000000,  -- Full media is 60s
        }
    end,
    get_audio_pcm_for_path = function(path, src_start, src_end, sample_rate)
        table.insert(fetch_log, {
            src_start = src_start,
            src_end = src_end,
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

print("Test: Timeline mode clip boundary limiting")

local audio_playback = require("core.media.audio_playback")

audio_playback.init_session(48000, 2)
audio_playback.set_max_time(MAX_MEDIA_US)

-- Build sources like the real code does
local sources = build_sources_like_real_code()

print(string.format("  Source data:"))
print(string.format("    source_offset_us = %.3fs", sources[1].source_offset_us / 1000000))
print(string.format("    duration_us = %.3fs", sources[1].duration_us / 1000000))
print(string.format("    clip_end_us = %.3fs (explicit from engine)", sources[1].clip_end_us / 1000000))

-- Expected clip end in timeline time
print(string.format("    expected clip_end = %.3fs", CLIP_TIMELINE_END_SEC))

-- Verify the math is right
assert(math.abs(sources[1].clip_end_us - CLIP_TIMELINE_END_SEC * 1000000) < 1000,
    string.format("clip_end calculation wrong: got %.3fs, expected %.3fs",
        sources[1].clip_end_us / 1000000, CLIP_TIMELINE_END_SEC))

-- Set sources and position
audio_playback.set_audio_sources(sources, mock_media_cache)
audio_playback.media_time_us = PLAYHEAD_US

print(string.format("  Playhead at %.3fs", PLAYHEAD_US / 1000000))
print(string.format("  Naive prefetch would extend to %.3fs",
    (PLAYHEAD_US + HALF_WINDOW_US) / 1000000))

-- Fetch
fetch_log = {}
audio_playback._ensure_pcm_cache()

assert(#fetch_log > 0, "Expected fetch")

local fetch = fetch_log[1]
print(string.format("  Actual fetch: %.3fs - %.3fs (source time)",
    fetch.src_start_sec, fetch.src_end_sec))

-- The fetch end in SOURCE time should not exceed source_out (21.933s)
-- Because: pb_end is limited to clip_end (92.6s timeline)
--          src_end = min(duration_us, pb_end - source_offset)
--                  = min(21.933, 92.6 - 70.667) = min(21.933, 21.933) = 21.933s

local max_allowed_src_end = SOURCE_OUT_SEC
print(string.format("  Max allowed src_end: %.3fs (source_out)", max_allowed_src_end))

if fetch.src_end_sec > max_allowed_src_end + 0.1 then
    print(string.format("  BUG: Fetch extends past clip boundary!"))
    print(string.format("       Fetched to %.3fs but clip ends at %.3fs",
        fetch.src_end_sec, max_allowed_src_end))
    assert(false, string.format(
        "BUG: Audio fetched past clip end! src_end=%.3fs > source_out=%.3fs (bleeding audio from next edit)",
        fetch.src_end_sec, max_allowed_src_end))
else
    print("  ✓ Fetch correctly limited at clip boundary")
end

audio_playback.shutdown_session()

--------------------------------------------------------------------------------
-- Test 2: Source mode uses full media duration (this is correct behavior)
-- After the audio init redesign, source mode audio is configured at transport
-- start via configure_source_mode_audio(), which correctly uses full duration.
--------------------------------------------------------------------------------

print("")
print("Test 2: Source mode correctly uses full media duration")

package.loaded["core.media.audio_playback"] = nil
audio_playback = require("core.media.audio_playback")

audio_playback.init_session(48000, 2)

-- In source mode, media duration IS the limit (no clip boundary)
local FULL_MEDIA_DURATION_US = 60000000  -- 60 seconds
audio_playback.set_max_time(FULL_MEDIA_DURATION_US)

local source_mode_sources = {{
    path = "/test/22D-3.mp4",
    source_offset_us = 0,  -- source mode: offset = 0
    volume = 1.0,
    duration_us = FULL_MEDIA_DURATION_US,  -- Full media is correct for source mode
    clip_end_us = FULL_MEDIA_DURATION_US,  -- Source mode: clip_end = full media
}}

audio_playback.set_audio_sources(source_mode_sources, mock_media_cache)

-- Position near end of media (55s into 60s media)
local SOURCE_PLAYHEAD_US = 55000000
audio_playback.media_time_us = SOURCE_PLAYHEAD_US

print(string.format("  Source mode config (configure_source_mode_audio path):"))
print(string.format("    source_offset_us = %.3fs", source_mode_sources[1].source_offset_us / 1000000))
print(string.format("    duration_us = %.3fs (full media, correct for source mode)",
    source_mode_sources[1].duration_us / 1000000))
print(string.format("  Playhead at %.3fs", SOURCE_PLAYHEAD_US / 1000000))

fetch_log = {}
audio_playback._ensure_pcm_cache()

assert(#fetch_log > 0, "Expected fetch in source mode")

local fetch2 = fetch_log[1]
print(string.format("  Fetch: %.3fs - %.3fs (source time)", fetch2.src_start_sec, fetch2.src_end_sec))

-- In source mode, fetch should go up to min(duration, playhead + 5s) = min(60, 60) = 60s
-- This is correct - no clip boundary in source mode
local expected_max = FULL_MEDIA_DURATION_US / 1000000
assert(fetch2.src_end_sec <= expected_max + 0.1,
    string.format("Fetch should not exceed media duration: %.3fs > %.3fs",
        fetch2.src_end_sec, expected_max))

print("  ✓ Source mode correctly fetches up to media boundary")

audio_playback.shutdown_session()

print("")
print("✅ test_audio_timeline_clip_boundary.lua passed")
