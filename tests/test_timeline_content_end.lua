#!/usr/bin/env luajit

-- Regression: B5 — Timeline playback must stop at end of content,
-- not at an arbitrary 1-hour placeholder.

require("test_env")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

print("\n=== B5: Timeline content end detection ===")

local data = require("ui.timeline.state.timeline_state_data")
local clip_state = require("ui.timeline.state.clip_state")

-- Set sequence rate
data.state.sequence_frame_rate = {fps_numerator = 24, fps_denominator = 1}

-- ─── Test 1: Empty timeline → content end is 0 ───
print("\n--- empty timeline → content end is 0 ---")
do
    data.state.clips = {}
    data.state.tracks = {}
    clip_state.invalidate_indexes()

    local end_frame = clip_state.get_content_end_frame()
    check("empty timeline → 0", end_frame == 0)
end

-- ─── Test 2: Single clip → content end is clip start + duration ───
print("\n--- single clip → correct end ---")
do
    data.state.clips = {
        {
            id = "c1", track_id = "t1",
            timeline_start = 0, duration = 100,
            source_in = 0, source_out = 100,
            fps_numerator = 24, fps_denominator = 1,
        },
    }
    data.state.tracks = {{id = "t1"}}
    clip_state.invalidate_indexes()

    local end_frame = clip_state.get_content_end_frame()
    check("single clip → 100", end_frame == 100)
end

-- ─── Test 3: Two tracks, different ends → max wins ───
print("\n--- two tracks → max end ---")
do
    data.state.clips = {
        {
            id = "c1", track_id = "t1",
            timeline_start = 0, duration = 100,
            source_in = 0, source_out = 100,
            fps_numerator = 24, fps_denominator = 1,
        },
        {
            id = "c2", track_id = "t2",
            timeline_start = 50, duration = 200,
            source_in = 0, source_out = 200,
            fps_numerator = 24, fps_denominator = 1,
        },
    }
    data.state.tracks = {{id = "t1"}, {id = "t2"}}
    clip_state.invalidate_indexes()

    local end_frame = clip_state.get_content_end_frame()
    check("two tracks → 250", end_frame == 250)
end

-- ─── Test 4: Clip with Rational values ───
print("\n--- Rational clip values → correct end ---")
do
    data.state.clips = {
        {
            id = "c1", track_id = "t1",
            timeline_start = 10,
            duration = 90,
            source_in = 0,
            source_out = 90,
            fps_numerator = 24, fps_denominator = 1,
        },
    }
    data.state.tracks = {{id = "t1"}}
    clip_state.invalidate_indexes()

    local end_frame = clip_state.get_content_end_frame()
    check("Rational clip → 100", end_frame == 100)
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_timeline_content_end.lua passed")
