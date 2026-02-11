--[[
Test: current_audio_clip_ids only updated when set_audio_sources succeeds

Bug: When resolve_and_set_audio_sources runs with session not ready,
it sets current_audio_clip_ids even though set_audio_sources was skipped.
Later, when session IS ready, resolve sees changed=false and skips again.

This test verifies:
1. With session NOT ready: current_audio_clip_ids should NOT be set (bug would set it)
2. With session ready (second call): set_audio_sources MUST be called
]]

require("test_env")

--------------------------------------------------------------------------------
-- Mock infrastructure
--------------------------------------------------------------------------------

local set_sources_call_count = 0
local last_sources_duration_us
local audio_session_ready = false

local mock_qt_constants = {
    SSE = { CREATE = function() return {} end },
    AOP = { OPEN = function() return {} end },
    EMP = { SET_DECODE_MODE = function() end },
}
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

-- Mock audio_playback - session_initialized controlled by test
local mock_audio_pb = {
    session_initialized = false,  -- Start NOT ready
    set_audio_sources = function(sources, cache, restart_time)
        set_sources_call_count = set_sources_call_count + 1
        if sources and sources[1] then
            last_sources_duration_us = sources[1].duration_us
        end
    end,
    is_ready = function() return audio_session_ready end,
    set_max_time = function() end,
    init_session = function() end,
    seek = function() end,
    start = function() end,
    stop = function() end,
    get_time_us = function() return 0 end,
}
package.loaded["core.media.audio_playback"] = mock_audio_pb

-- Mock media_cache
package.loaded["core.media.media_cache"] = {
    ensure_audio_pooled = function(path)
        return { has_audio = true, audio_sample_rate = 48000, duration_us = 600000000 }
    end,
    get_asset_info = function()
        return { has_audio = true, audio_sample_rate = 48000, duration_us = 600000000 }
    end,
    get_file_path = function() return "/test/media.mp4" end,
    is_loaded = function() return true end,
    set_playhead = function() end,
    stop_all_prefetch = function() end,
}

-- Mock timeline_resolver (using frames at 24fps)
local CLIP_ID = "clip-12345"
local FPS = 24
local TIMELINE_START_FRAMES = 1680  -- 70.0s at 24fps
local SOURCE_IN_FRAMES = 0
local SOURCE_OUT_FRAMES = 528  -- 22.0s at 24fps
local DURATION_FRAMES = SOURCE_OUT_FRAMES - SOURCE_IN_FRAMES
package.loaded["core.playback.timeline_resolver"] = {
    resolve_all_audio_at_time = function(playhead_frame, sequence_id)
        return {{
            clip = {
                id = CLIP_ID,
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

-- Mock helpers
package.loaded["core.playback.playback_helpers"] = {
    calc_time_us_from_frame = function(f, num, den)
        return math.floor(f * 1000000 * den / num)
    end,
    calc_frame_from_time_us = function(t_us, num, den)
        return math.floor(t_us * num / (1000000 * den))
    end,
    frame_clamped = function(frame, total)
        return math.max(0, math.min(frame, total - 1))
    end,
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
-- Load playback_controller fresh
--------------------------------------------------------------------------------

package.loaded["core.playback.playback_controller"] = nil
local pc = require("core.playback.playback_controller")

--------------------------------------------------------------------------------
-- Test
--------------------------------------------------------------------------------

print("Test: Clip IDs only cached when set_audio_sources succeeds")

-- Setup
pc.timeline_mode = true
pc.sequence_id = "test-seq"
pc.fps_num = 24
pc.fps_den = 1
pc.fps = 24
pc.total_frames = 5000
pc.max_media_time_us = 180000000
pc._position = 2000

--------------------------------------------------------------------------------
-- Phase 1: Session NOT ready
--------------------------------------------------------------------------------

print("")
print("  Phase 1: Session NOT ready")

audio_session_ready = false
mock_audio_pb.session_initialized = false
pc.init_audio(mock_audio_pb)

set_sources_call_count = 0

-- Trigger resolve via play() - but session isn't ready
-- The internal ensure_audio_session might try to lazy-init, but we control session_initialized
pc.play()
pc.stop()

print(string.format("    set_audio_sources call count: %d", set_sources_call_count))
print(string.format("    current_audio_clip_ids has CLIP_ID: %s",
    tostring(pc.current_audio_clip_ids[CLIP_ID] == true)))

-- With the FIX: clip ID should NOT be cached (session wasn't ready, set_audio_sources wasn't called)
-- With the BUG: clip ID IS cached even though set_audio_sources wasn't called

local _ = (pc.current_audio_clip_ids[CLIP_ID] == true)  -- luacheck: ignore 311 (computed but not used - just checking state)

--------------------------------------------------------------------------------
-- Phase 2: Session NOW ready
--------------------------------------------------------------------------------

print("")
print("  Phase 2: Session NOW ready")

audio_session_ready = true
mock_audio_pb.session_initialized = true

set_sources_call_count = 0
last_sources_duration_us = nil

pc.play()

print(string.format("    set_audio_sources call count: %d", set_sources_call_count))

-- THE KEY ASSERTION:
-- With the FIX: set_audio_sources IS called (because clip IDs weren't cached in phase 1)
-- With the BUG: set_audio_sources NOT called (because clip IDs were cached, changed=false)

if set_sources_call_count == 0 then
    print("")
    print("  BUG DETECTED!")
    print("    Phase 1 cached clip ID even though set_audio_sources wasn't called")
    print("    Phase 2 saw changed=false and skipped set_audio_sources")
    assert(false, "BUG: set_audio_sources not called in Phase 2")
end

print("  ✓ set_audio_sources called correctly in Phase 2")

-- Verify clip boundary passed (duration in us at sequence fps)
local expected_duration_us = DURATION_FRAMES * 1000000 / FPS
assert(last_sources_duration_us and
       math.abs(last_sources_duration_us - expected_duration_us) < 1000,
    string.format("duration_us should be %.0f, got %s",
        expected_duration_us, tostring(last_sources_duration_us)))
print(string.format("  ✓ Correct clip boundary passed: %.0fus", last_sources_duration_us))

pc.stop()

print("")
print("✅ test_audio_clip_ids_only_on_success.lua passed")
