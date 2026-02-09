#!/usr/bin/env luajit

-- Test that trim operations cannot create negative duration clips
-- Clips have minimum duration of 1 frame; gaps can reach duration=0

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test 1: In-point trim clamps to minimum duration (1 frame)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_min_duration_in.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 10}  -- 10 frames = tiny clip
        }
    })

    local before_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local before_right = Clip.load(layout.clips.v1_right.id, layout.db)

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "in", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 15)  -- Try to trim 15 frames from 10-frame clip

    local result = command_manager.execute(cmd)
    assert(result.success, "Trim beyond minimum should clamp and succeed")

    local after = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(after.duration == 1,
        string.format("Clamped trim should stop at 1 frame, got %d frames", after.duration))
    assert(after.timeline_start == before_left.timeline_start,
        "In-edge trim should not move timeline_start for ripple edits")

    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    assert(after_right.timeline_start == before_right.timeline_start - 9,
        string.format("Downstream clip should ripple left by 9 frames, got %d", after_right.timeline_start))

    layout:cleanup()
end

-- Test 2: Out-point trim clamps to minimum duration (1 frame)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_min_duration_out.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 10}
        }
    })

    local before_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local before_right = Clip.load(layout.clips.v1_right.id, layout.db)

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", -15)  -- Try to shrink by 15 frames

    local result = command_manager.execute(cmd)
    assert(result.success, "Trim beyond minimum should clamp and succeed")

    local after = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(after.duration == 1,
        string.format("Clamped trim should stop at 1 frame, got %d", after.duration))
    assert(after.timeline_start == before_left.timeline_start,
        "Out-edge trim should not move timeline_start")

    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    assert(after_right.timeline_start == before_right.timeline_start - 9,
        string.format("Downstream clip should ripple left by 9 frames, got %d", after_right.timeline_start))

    layout:cleanup()
end

-- Test 3: Single-frame clip trim clamps to no-op (cannot go below 1 frame)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_single_frame.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1}  -- Already 1 frame
        }
    })

    local before = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(before.duration == 1, "Setup: clip should be 1 frame")

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", -1)  -- Try to shrink by 1 frame

    local result = command_manager.execute(cmd)
    assert(result.success, "Trim of single-frame clip should clamp to no-op")

    local after = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(after.duration == 1,
        string.format("Clamped operation leaves single-frame clip unchanged, got %d", after.duration))

    layout:cleanup()
end

-- Test 4: Gap can reach duration=0 (gaps can close completely)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_gap_zero_duration.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}  -- 1000 frame gap
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "gap_after", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 1000)  -- Close the gap completely

    local result = command_manager.execute(cmd)
    assert(result.success, "Gap closure should succeed")

    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    assert(after_right.timeline_start == 1000,
        string.format("Right clip should butt against left clip (gap=0), got start=%d",
            after_right.timeline_start))

    layout:cleanup()
end

-- Test 5: Gap_before trying to close beyond zero should clamp
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_gap_overclose.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 1500, duration = 1000}  -- 500 frame gap
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_right.id, edge_type = "gap_before", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", -800)  -- Try to close 800 frames (gap only 500)

    local result = command_manager.execute(cmd)
    assert(result.success, "Gap overclose should clamp")

    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    -- Should clamp to gap size (500 frames) max closure
    assert(after_right.timeline_start == 1000,
        string.format("Should clamp to butt against left clip, got start=%d",
            after_right.timeline_start))

    layout:cleanup()
end

-- Test 6: Roll edit clamps to preserve minimum duration
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_roll_min_duration.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 5},  -- 5 frames
            v1_right = {timeline_start = 5, duration = 5}  -- 5 frames, adjacent
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id, trim_type = "roll"},
        {clip_id = layout.clips.v1_right.id, edge_type = "in", track_id = layout.tracks.v1.id, trim_type = "roll"}
    })
    cmd:set_parameter("delta_frames", 8)  -- Try to roll 8 frames right (would make right clip -3 frames)

    local result = command_manager.execute(cmd)
    assert(result.success, "Roll should clamp and succeed")

    local after_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)

    assert(after_left.duration == 9,
        string.format("Left clip should extend by 4 frames (clamped), got %d", after_left.duration))
    assert(after_right.duration == 1,
        string.format("Right clip should shrink to 1 frame (clamped), got %d", after_right.duration))
    assert(after_right.timeline_start == 9,
        string.format("Right clip should roll to start at 9, got %d", after_right.timeline_start))

    layout:cleanup()
end

print("✅ Negative duration constraints enforced (minimum 1 frame for clips, 0 for gaps)")
