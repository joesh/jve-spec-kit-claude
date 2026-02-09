#!/usr/bin/env luajit

-- Test: magnetic_snapping with integer frame coordinates
-- Verifies snapping works with playhead, clip edges, and snapshot clips

package.path = package.path .. ";src/lua/?.lua;src/lua/?/init.lua;./?.lua;./?/init.lua"

local magnetic_snapping = require("core.magnetic_snapping")

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

-- Stub state exposing minimal API (all coords are integer frames)
local sequence_fps_num = 24
local sequence_fps_den = 1
local state = {
    get_sequence_fps_numerator = function() return sequence_fps_num end,
    get_sequence_fps_denominator = function() return sequence_fps_den end,
    get_playhead_position = function() return 12 end, -- 0.5 seconds at 24fps
    get_sequence_frame_rate = function() return {fps_numerator = sequence_fps_num, fps_denominator = sequence_fps_den} end,
    time_to_pixel = function(frame, _viewport_width_px)
        return frame -- 1:1 mapping for testing
    end,
    get_clips = function()
        return {
            {id = "clip_a", timeline_start = 24, duration = 12},  -- 1s start, ~0.5s duration
            {id = "clip_b", timeline_start = 60, duration = 12},  -- 2.5s start
        }
    end
}

-- Integer target at frame 24 should snap to clip_a in edge
local target = 24
local snapped_time, info = magnetic_snapping.apply_snap(state, target, true, {}, {}, 50)
assert_true(type(snapped_time) == "number", "Snapped time should be an integer")
assert_equal(snapped_time, 24, "Target should snap to clip in-point frame 24")
assert_equal(info.snapped, true, "Snap should trigger for close target")

-- Target near playhead (frame 12) should snap to playhead
local near_playhead = 12
local snapped_playhead, info2 = magnetic_snapping.apply_snap(state, near_playhead, true, {}, {}, 100)
assert_true(type(snapped_playhead) == "number", "Snapped playhead should be an integer")
assert_equal(snapped_playhead, 12, "Target near playhead should snap to playhead frame 12")
assert_equal(info2.snapped, true, "Snap should trigger for playhead")

-- Clip snapshot scoping: snapping must not require state.get_clips when an
-- explicit clip universe is provided (used by TimelineActiveRegion edge drags).
local state_without_get_clips = {
    get_sequence_fps_numerator = function() return sequence_fps_num end,
    get_sequence_fps_denominator = function() return sequence_fps_den end,
    get_playhead_position = function() return 12 end,
    get_sequence_frame_rate = function() return {fps_numerator = sequence_fps_num, fps_denominator = sequence_fps_den} end,
    time_to_pixel = function(frame, _viewport_width_px)
        return frame
    end,
    get_clips = function()
        error("get_clips should not be called when clip_snapshot is provided")
    end
}

local snapshot = {
    clips = {
        {id = "clip_c", timeline_start = 100, duration = 10}
    }
}

local target_snapshot = 100
local snapped_snapshot, info3 = magnetic_snapping.apply_snap(state_without_get_clips, target_snapshot, true, {}, {}, 100, {clip_snapshot = snapshot})
assert_true(type(snapped_snapshot) == "number", "Snapshot snap time should be an integer")
assert_equal(snapped_snapshot, 100, "Snapshot target should snap to snapshot clip in-point")
assert_equal(info3.snapped, true, "Snap should trigger for snapshot clip")

print("test_magnetic_snapping_rational.lua passed")
