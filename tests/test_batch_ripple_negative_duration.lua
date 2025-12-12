#!/usr/bin/env luajit

-- Test that trim operations cannot create negative duration clips
-- Clips have minimum duration of 1 frame; gaps can reach duration=0

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test 1: In-point trim that would make duration < 1 frame currently fails
-- NOTE: Current behavior is FAIL, not clamp. This documents actual behavior.
-- Future enhancement: Could clamp to 1 frame and succeed with warning.
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_min_duration_in.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 10}  -- 10 frames = tiny clip
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "in", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 15)  -- Try to trim 15 frames from 10-frame clip

    local result = command_manager.execute(cmd)
    -- Current behavior: operation fails when trim would create duration < 1
    assert(not result.success, "Trim beyond minimum currently fails (apply_edge_ripple returns false)")

    -- Clip should be unchanged
    local after = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(after.duration.frames == 10,
        string.format("Failed trim should leave clip unchanged, got %d frames", after.duration.frames))

    layout:cleanup()
end

-- Test 2: Out-point trim that would make duration < 1 frame currently fails
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_min_duration_out.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 10}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", -15)  -- Try to shrink by 15 frames

    local result = command_manager.execute(cmd)
    assert(not result.success, "Trim beyond minimum fails (same as test 1)")

    local after = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(after.duration.frames == 10,
        string.format("Failed trim should leave clip unchanged, got %d", after.duration.frames))

    layout:cleanup()
end

-- Test 3: Single-frame clip trim by 1 frame currently fails
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_single_frame.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1}  -- Already 1 frame
        }
    })

    local before = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(before.duration.frames == 1, "Setup: clip should be 1 frame")

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", -1)  -- Try to shrink by 1 frame

    local result = command_manager.execute(cmd)
    assert(not result.success, "Trim of single-frame clip fails (would create 0 frames)")

    local after = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(after.duration.frames == 1,
        string.format("Failed operation leaves single-frame clip unchanged, got %d", after.duration.frames))

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
    assert(after_right.timeline_start.frames == 1000,
        string.format("Right clip should butt against left clip (gap=0), got start=%d",
            after_right.timeline_start.frames))

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
    assert(after_right.timeline_start.frames == 1000,
        string.format("Should clamp to butt against left clip, got start=%d",
            after_right.timeline_start.frames))

    layout:cleanup()
end

-- Test 6: Roll edit that would violate minimum duration currently fails
-- NOTE: Constraint system doesn't clamp roll operations - they fail instead
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
    -- Current behavior: Roll operations fail if they would violate minimum duration
    -- Constraint system calculates limits but apply_edge_ripple still returns failure
    assert(not result.success, "Roll that would create negative duration fails")

    local after_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)

    assert(after_left.duration.frames == 5,
        string.format("Failed roll leaves left clip unchanged, got %d", after_left.duration.frames))
    assert(after_right.duration.frames == 5,
        string.format("Failed roll leaves right clip unchanged, got %d", after_right.duration.frames))

    layout:cleanup()
end

print("✅ Negative duration constraints enforced (minimum 1 frame for clips, 0 for gaps)")
