#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

local timeline_state = require("ui.timeline.timeline_state")
local time_utils = require("core.time_utils")

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual:   %s", message or "", tostring(expected), tostring(actual)))
    end
end

-- Reset to an empty in-memory state
timeline_state.reset()

-- Playhead rational conversion round-trip (frames@24fps)
timeline_state.set_playhead_value(48) -- 2s @24fps
local playhead_rt = timeline_state.get_playhead_rational()
assert_equal(playhead_rt.rate, 24.0, "Playhead RationalTime should use sequence frame rate")
assert_equal(playhead_rt.value, 48, "Playhead should report native frames")

timeline_state.set_playhead_rational(time_utils.from_frames(72, 24))
assert_equal(timeline_state.get_playhead_value(), 72, "Playhead should store native frames")

-- Viewport rational conversion (start/duration)
timeline_state.set_viewport_rational(
    time_utils.from_frames(24, 24),   -- 1s
    time_utils.from_frames(48, 24)    -- 2s
)
local viewport_rt = timeline_state.get_viewport_rational()
assert_equal(viewport_rt.start.value, 24, "Viewport start should be 24 frames at 24fps")
assert_equal(viewport_rt.duration.value, 48, "Viewport span should be 48 frames at 24fps")
assert_equal(timeline_state.get_viewport_start_value(), 24, "Viewport start stored in native frames")
assert_equal(timeline_state.get_viewport_duration_frames_value(), 48, "Viewport duration stored in native frames")

-- Coordinate conversions (RationalTime aware)
local px = timeline_state.time_rational_to_pixel(time_utils.from_frames(36, 24), 240) -- midway through 1s..3s window
local rt_from_px = timeline_state.pixel_to_rational(px, 240)
assert_equal(rt_from_px.rate, 24, "pixel_to_rational should use sequence fps")
assert_equal(rt_from_px.value, 36, "pixel_to_rational should map back to frame count")

print("✅ timeline_state RationalTime tests passed")
