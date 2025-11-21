#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

local roll_detector = require('ui.timeline.roll_detector')

local function make_clip(id, track_id, start_value, duration_value)
    return {
        id = id,
        track_id = track_id,
        start_value = start_value,
        duration_value = duration_value,
        timebase_type = "video_frames",
        timebase_rate = 30
    }
end

local function always_allow_roll()
    return true
end

do
    local clip_a = make_clip("clip_a", "track_v1", 0, 1000)
    local clip_b = make_clip("clip_b", "track_v1", 1000, 500)
    local entries = {
        {clip = clip_a, edge = "out", distance = 3},
        {clip = clip_b, edge = "in", distance = 4},
    }

    local selection, pair = roll_detector.find_best_roll_pair(entries, 250, 1920, always_allow_roll)
    assert(selection and #selection == 2, "Expected roll selection for clip pair")
    assert(selection[1].edge_type == "out" and selection[2].edge_type == "in", "Clip pair selection should use in/out edges")
    assert(pair and pair.roll_kind == "clip_clip", "Expected clip_clip metadata")
    assert(math.abs((pair.edit_time or 0) - 1000) < 1, "Edit time should match clip boundary")
end

do
    local clip_a = make_clip("clip_gap", "track_v1", 0, 800)
    local entries = {
        {clip = clip_a, edge = "gap_after", distance = 2}
    }

    local selection, pair = roll_detector.find_best_roll_pair(entries, 400, 1920, always_allow_roll)
    assert(selection and #selection == 2, "Expected roll selection for clip-gap boundary")
    assert(selection[1].edge_type == "out", "Roll selection should include clip out edge for gap")
    assert(selection[2].edge_type == "gap_after", "Roll selection should include gap edge")
    assert(pair and pair.roll_kind == "clip_gap_after", "Metadata should reflect clip-gap pair")
    assert(pair.left_target.edge_type == "out", "Left target should be clip out edge")
    assert(pair.right_target.edge_type == "gap_after", "Right target should be gap edge")
end

print("✅ roll selection tests passed")
