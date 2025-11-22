#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

local magnetic_snapping = require("core.magnetic_snapping")
local time_utils = require("core.time_utils")

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual:   %s", message or "", tostring(expected), tostring(actual)))
    end
end

-- Stub state exposing minimal API
local sequence_rate = 24
local state = {
    get_sequence_frame_rate = function() return sequence_rate end,
    get_playhead_value = function() return 12 end, -- 0.5 seconds at 24fps
    get_clips = function()
        return {
            {id = "clip_a", start_value = 24, duration = 12},  -- 1s start, ~0.5s duration
            {id = "clip_b", start_value = 60, duration = 12},  -- 2.5s start
        }
    end
}

-- Rational target at 1s should snap to clip_a in edge
local target_rt = time_utils.from_frames(24, sequence_rate) -- 1s
local snapped_time, info = magnetic_snapping.apply_snap(state, target_rt, true, {}, {}, 50)
assert_equal(snapped_time, 24, "RationalTime target should snap to clip in-point in frames")
assert_equal(info.snapped, true, "Snap should trigger for close rational target")

-- Rational target near playhead should snap to playhead
local near_playhead = time_utils.from_frames(12, sequence_rate) -- 0.5s
local snapped_playhead, info2 = magnetic_snapping.apply_snap(state, near_playhead, true, {}, {}, 100)
assert_equal(snapped_playhead, 12, "RationalTime near playhead should snap to playhead frame value")
assert_equal(info2.snapped, true, "Snap should trigger for playhead")

print("✅ magnetic_snapping RationalTime tests passed")
