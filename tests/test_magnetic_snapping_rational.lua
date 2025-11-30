#!/usr/bin/env luajit

package.path = package.path .. ";src/lua/?.lua;src/lua/?/init.lua;./?.lua;./?/init.lua"

local magnetic_snapping = require("core.magnetic_snapping")
local time_utils = require("core.time_utils")
local Rational = require("core.rational")

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual:   %s", message or "", tostring(expected), tostring(actual)))
    end
end

local function assert_true(condition, message)
    if not condition then
        error(string.format("Assertion failed: %s\nCondition was false.", message or ""))
    end
end

-- Stub state exposing minimal API
local sequence_fps_num = 24
local sequence_fps_den = 1
local state = {
    get_sequence_fps_numerator = function() return sequence_fps_num end,
    get_sequence_fps_denominator = function() return sequence_fps_den end,
    get_playhead_value = function() return time_utils.from_frames(12, sequence_fps_num, sequence_fps_den) end, -- 0.5 seconds at 24fps
    get_clips = function()
        return {
            {id = "clip_a", timeline_start_frame = time_utils.from_frames(24, sequence_fps_num, sequence_fps_den), duration_frames = time_utils.from_frames(12, sequence_fps_num, sequence_fps_den)},  -- 1s start, ~0.5s duration
            {id = "clip_b", timeline_start_frame = time_utils.from_frames(60, sequence_fps_num, sequence_fps_den), duration_frames = time_utils.from_frames(12, sequence_fps_num, sequence_fps_den)},  -- 2.5s start
        }
    end
}

-- Rational target at 1s should snap to clip_a in edge
local target_rt = time_utils.from_frames(24, sequence_fps_num, sequence_fps_den) -- 1s
local snapped_time, info = magnetic_snapping.apply_snap(state, target_rt, true, {}, {}, 50)
assert_true(getmetatable(snapped_time) == Rational.metatable, "Snapped time should be a Rational object")
assert_equal(snapped_time.frames, 24, "RationalTime target should snap to clip in-point frames")
assert_equal(snapped_time.fps_numerator, sequence_fps_num, "RationalTime target should snap to clip in-point fps_numerator")
assert_equal(info.snapped, true, "Snap should trigger for close rational target")

-- Rational target near playhead should snap to playhead
local near_playhead = time_utils.from_frames(12, sequence_fps_num, sequence_fps_den) -- 0.5s
local snapped_playhead, info2 = magnetic_snapping.apply_snap(state, near_playhead, true, {}, {}, 100)
assert_true(getmetatable(snapped_playhead) == Rational.metatable, "Snapped playhead should be a Rational object")
assert_equal(snapped_playhead.frames, 12, "RationalTime near playhead should snap to playhead frame value")
assert_equal(snapped_playhead.fps_numerator, sequence_fps_num, "RationalTime near playhead should snap to playhead fps_numerator")
assert_equal(info2.snapped, true, "Snap should trigger for playhead")

print("✅ magnetic_snapping RationalTime tests passed")
