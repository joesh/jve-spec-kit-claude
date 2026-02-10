--[[
Test: Audio clip duration correctly computed as (source_out - source_in)

Bug: When source_in > 0, using source_out as duration causes over-fetching.
source_out is an ENDPOINT, not a DURATION.

Example:
  - source_in = 6.734s (clip starts at 6.734s in source media)
  - source_out = 33.667s (clip ends at 33.667s in source media)
  - Actual duration = 33.667 - 6.734 = 26.933s

With the bug:
  - duration_us = source_out = 33.667s
  - clip_end = offset + 33.667 = too far!
  - Audio fetches past the edit point

With the fix:
  - duration_us = source_out - source_in = 26.933s
  - clip_end = offset + 26.933 = correct!
]]

require("test_env")

--------------------------------------------------------------------------------
-- Mock infrastructure
--------------------------------------------------------------------------------

local captured_sources = nil

local mock_qt_constants = {
    SSE = { CREATE = function() return {} end },
    AOP = { OPEN = function() return {} end },
    EMP = { SET_DECODE_MODE = function() end },
}
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

local mock_audio_pb = {
    session_initialized = true,
    set_audio_sources = function(sources, cache, restart_time)
        captured_sources = sources
    end,
    is_ready = function() return true end,
    set_max_time = function() end,
    seek = function() end,
    start = function() end,
    stop = function() end,
    get_time_us = function() return 0 end,
}
package.loaded["core.media.audio_playback"] = mock_audio_pb

package.loaded["core.media.media_cache"] = {
    ensure_audio_pooled = function() return { has_audio = true, audio_sample_rate = 48000, duration_us = 600000000 } end,
    get_asset_info = function() return { has_audio = true, audio_sample_rate = 48000, duration_us = 600000000 } end,
    get_file_path = function() return "/test/media.mp4" end,
    is_loaded = function() return true end,
    set_playhead = function() end,
    stop_all_prefetch = function() end,
}

-- Mock timeline_resolver with source_in > 0
-- Using frame counts: clips play at sequence rate (24fps in this test)
local FPS = 24
local SOURCE_IN_FRAMES = 162     -- ~6.734s at 24fps
local SOURCE_OUT_FRAMES = 808    -- ~33.667s at 24fps
local TIMELINE_START_FRAMES = 1576  -- ~65.667s at 24fps
local DURATION_FRAMES = SOURCE_OUT_FRAMES - SOURCE_IN_FRAMES  -- 646 frames

-- For display in test output
local SOURCE_IN_SEC = SOURCE_IN_FRAMES / FPS
local SOURCE_OUT_SEC = SOURCE_OUT_FRAMES / FPS
local TIMELINE_START_SEC = TIMELINE_START_FRAMES / FPS
local EXPECTED_DURATION_SEC = DURATION_FRAMES / FPS

package.loaded["core.playback.timeline_resolver"] = {
    resolve_all_audio_at_time = function(playhead_frame, sequence_id)
        return {{
            clip = {
                id = "test-clip",
                timeline_start = TIMELINE_START_FRAMES,
                source_in = SOURCE_IN_FRAMES,
                source_out = SOURCE_OUT_FRAMES,
                rate = { fps_numerator = FPS, fps_denominator = 1 },
            },
            track = { volume = 1.0, muted = false, soloed = false },
            media_path = "/test/clip.mp4",
        }}
    end,
}

package.loaded["core.playback.playback_helpers"] = {
    calc_time_us_from_frame = function(f, num, den) return math.floor(f * 1000000 * den / num) end,
    calc_frame_from_time_us = function(t_us, num, den) return math.floor(t_us * num / (1000000 * den)) end,
    frame_clamped = function(frame, total) return math.max(0, math.min(frame, total - 1)) end,
    sync_audio = function() end,
    stop_audio = function() end,
}

package.loaded["core.logger"] = {
    debug = function() end, info = function() end,
    warn = function() end, error = function() end, trace = function() end,
}
package.loaded["core.playback.source_playback"] = { get_unlatch_resume_time = function() return 0 end }
package.loaded["core.playback.timeline_playback"] = {}
package.loaded["ui.timeline.timeline_state"] = {
    get_playhead_position = function() return 2000 end,
    set_playhead_position = function() end,
    get_sequence_frame_rate = function() return { fps_numerator = 24, fps_denominator = 1 } end,
}
_G.qt_create_single_shot_timer = function() end

--------------------------------------------------------------------------------
-- Test
--------------------------------------------------------------------------------

package.loaded["core.playback.playback_controller"] = nil
local pc = require("core.playback.playback_controller")

print("Test: Audio clip duration computed as (source_out - source_in)")
print(string.format("  source_in = %.3fs", SOURCE_IN_SEC))
print(string.format("  source_out = %.3fs", SOURCE_OUT_SEC))
print(string.format("  Expected duration = %.3fs", EXPECTED_DURATION_SEC))

-- Setup
pc.timeline_mode = true
pc.sequence_id = "test-seq"
pc.fps_num = 24
pc.fps_den = 1
pc.fps = 24
pc.total_frames = 5000
pc.max_media_time_us = 180000000
pc._position = 2000
pc.init_audio(mock_audio_pb)

captured_sources = nil
pc.play()

assert(captured_sources, "set_audio_sources should have been called")
assert(#captured_sources == 1, "Expected 1 source")

local actual_duration_us = captured_sources[1].duration_us
local actual_duration_sec = actual_duration_us / 1000000
local expected_duration_us = EXPECTED_DURATION_SEC * 1000000

print(string.format("  Actual duration_us = %.3fs", actual_duration_sec))

-- THE KEY ASSERTION
-- With bug: duration = source_out = 33.667s
-- With fix: duration = source_out - source_in = 26.933s

if math.abs(actual_duration_us - expected_duration_us) < 1000 then
    print("  ✓ duration_us correctly computed as (source_out - source_in)")
else
    print("")
    print("  BUG DETECTED!")
    print(string.format("    Expected duration: %.3fs (source_out - source_in)", EXPECTED_DURATION_SEC))
    print(string.format("    Actual duration:   %.3fs", actual_duration_sec))
    if math.abs(actual_duration_sec - SOURCE_OUT_SEC) < 0.001 then
        print("    duration_us is source_out (endpoint), not (source_out - source_in) (duration)!")
    end
    assert(false, string.format(
        "BUG: duration_us = %.3fs, expected %.3fs",
        actual_duration_sec, EXPECTED_DURATION_SEC))
end

-- Also verify the source_offset is correct
local actual_offset_us = captured_sources[1].source_offset_us
local expected_offset_us = (TIMELINE_START_SEC - SOURCE_IN_SEC) * 1000000
print(string.format("  source_offset = %.3fs (timeline_start - source_in)", actual_offset_us / 1000000))
assert(math.abs(actual_offset_us - expected_offset_us) < 1000,
    string.format("source_offset should be %.3fs, got %.3fs",
        expected_offset_us / 1000000, actual_offset_us / 1000000))

pc.stop()

print("")
print("✅ test_audio_clip_duration_with_source_in.lua passed")
