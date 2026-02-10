--- Test: timeline mode prefetch uses source frame, not timeline frame
--
-- Regression: play()/shuttle()/slow_play() called media_cache.set_playhead()
-- with get_position() which returns the TIMELINE frame in timeline mode.
-- Prefetch interpreted it as a SOURCE frame → decoded at wrong position
-- (e.g., 70s instead of 6s). Stale cache rejections, no video.
--
-- The fix: transport controls skip set_playhead in timeline mode.
-- resolve_and_display inside tick() calls set_playhead with the correct
-- source frame derived from resolved.source_time_us.

require("test_env")

print("=== test_timeline_prefetch_source_frame.lua ===")

-- Mock qt_constants
local mock_qt_constants = {
    EMP = {
        SET_DECODE_MODE = function() end,
    },
}
_G.qt_constants = mock_qt_constants
package.loaded["core.qt_constants"] = mock_qt_constants

package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Track set_playhead calls
local set_playhead_calls = {}
package.loaded["core.media.media_cache"] = {
    is_loaded = function() return true end,
    set_playhead = function(frame, dir, speed)
        table.insert(set_playhead_calls, { frame = frame, dir = dir, speed = speed })
    end,
    get_asset_info = function()
        return { fps_num = 24000, fps_den = 1001, has_audio = false }
    end,
    activate = function() end,
    ensure_audio_pooled = function() end,
    stop_all_prefetch = function() end,
}

_G.qt_create_single_shot_timer = function() end

-- Mock viewer
local mock_viewer = {
    show_frame = function() end,
    show_frame_at_time = function() end,
    show_gap = function() end,
}

-- Mock timeline_state (playback_controller reads/writes playhead here in timeline mode)
local mock_playhead_rat = nil
package.loaded["ui.timeline.timeline_state"] = {
    get_playhead_position = function() return mock_playhead_rat end,
    set_playhead_position = function(rat) mock_playhead_rat = rat end,
    get_sequence_frame_rate = function()
        return { fps_numerator = 24000, fps_denominator = 1001 }
    end,
}

-- Mock timeline_resolver: clip at timeline 70s, source_time = 6.25s
local mock_clip = { id = "clip_A" }
package.loaded["core.playback.timeline_resolver"] = {
    resolve_at_time = function(playhead_rat, sequence_id)
        return {
            media_path = "/media/clip_a.mov",
            source_time_us = 6250000,  -- 6.25s into source
            clip = mock_clip,
        }
    end,
    resolve_all_audio_at_time = function(playhead_rat, sequence_id)
        return {}  -- no audio clips for this test
    end,
}

-- Load fresh
package.loaded["core.playback.playback_controller"] = nil
package.loaded["core.playback.source_playback"] = nil
package.loaded["core.playback.timeline_playback"] = nil
package.loaded["core.playback.playback_helpers"] = nil
local pc = require("core.playback.playback_controller")

pc.init(mock_viewer)

-- Enter timeline mode at 23.976fps. Playhead at timeline frame 1680 (~70s).
pc.set_timeline_mode(true, "seq_1", {
    fps_num = 24000,
    fps_den = 1001,
    total_frames = 86400,
})

-- Set playhead to timeline frame 1680 (= ~70.07s in timeline time)
-- This is the value get_position() returns in timeline mode.
local Rational = require("core.rational")
mock_playhead_rat = 1680
pc.set_position_silent(1680)

--------------------------------------------------------------------------------
-- Test 1: play() must NOT call set_playhead with timeline frame 1680
--------------------------------------------------------------------------------
print("Test 1: play() in timeline mode skips set_playhead (no stale prefetch)")

set_playhead_calls = {}
pc.play()

-- play() should NOT have called set_playhead at all in timeline mode.
-- The first tick's resolve_and_display will call it with the correct source frame.
assert(#set_playhead_calls == 0,
    string.format("play() should NOT call set_playhead in timeline mode, got %d calls (frame=%s)",
        #set_playhead_calls,
        #set_playhead_calls > 0 and tostring(set_playhead_calls[1].frame) or "n/a"))

print("  ✓ play() did not call set_playhead with timeline frame")
pc.stop()

--------------------------------------------------------------------------------
-- Test 2: shuttle() must NOT call set_playhead with timeline frame
--------------------------------------------------------------------------------
print("Test 2: shuttle() in timeline mode skips set_playhead")

set_playhead_calls = {}
pc.shuttle(1)

assert(#set_playhead_calls == 0,
    string.format("shuttle() should NOT call set_playhead in timeline mode, got %d calls",
        #set_playhead_calls))

print("  ✓ shuttle() did not call set_playhead with timeline frame")
pc.stop()

--------------------------------------------------------------------------------
-- Test 3: slow_play() must NOT call set_playhead with timeline frame
--------------------------------------------------------------------------------
print("Test 3: slow_play() in timeline mode skips set_playhead")

set_playhead_calls = {}
pc.slow_play(1)

assert(#set_playhead_calls == 0,
    string.format("slow_play() should NOT call set_playhead in timeline mode, got %d calls",
        #set_playhead_calls))

print("  ✓ slow_play() did not call set_playhead with timeline frame")
pc.stop()

--------------------------------------------------------------------------------
-- Test 4: source mode DOES call set_playhead (unchanged behavior)
--------------------------------------------------------------------------------
print("Test 4: play() in source mode still calls set_playhead")

pc.set_timeline_mode(false)
pc.set_source(1000, 24000, 1001)
pc.set_position_silent(500)

set_playhead_calls = {}
pc.play()

assert(#set_playhead_calls == 1,
    string.format("play() in source mode should call set_playhead, got %d calls",
        #set_playhead_calls))
assert(set_playhead_calls[1].frame == 500,
    string.format("set_playhead should get source frame 500, got %d",
        set_playhead_calls[1].frame))

print(string.format("  ✓ source mode: set_playhead(frame=%d)", set_playhead_calls[1].frame))
pc.stop()

--------------------------------------------------------------------------------
print()
print("✅ test_timeline_prefetch_source_frame.lua passed")
