#!/usr/bin/env luajit

-- Test that trim operations properly handle zero-duration clips
-- Clips trimmed to zero duration are DELETED; gaps can reach duration=0

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test 1: In-point trim beyond duration DELETES the clip
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_min_duration_in.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 10}  -- 10 frames = tiny clip
        }
    })

    local before_right = Clip.load(layout.clips.v1_right.id, layout.db)

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "in", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 15)  -- Try to trim 15 frames from 10-frame clip

    local result = command_manager.execute(cmd)
    assert(result.success, "Trim beyond duration should succeed (deletes clip)")

    local after = Clip.load_optional(layout.clips.v1_left.id, layout.db)
    assert(after == nil, "Clip trimmed beyond its duration should be DELETED")

    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    assert(after_right.timeline_start == before_right.timeline_start - 10,
        string.format("Downstream clip should ripple left by 10 frames (full clip), got %d", after_right.timeline_start))

    layout:cleanup()
end

-- Test 2: Out-point trim beyond duration DELETES the clip
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_min_duration_out.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 10}
        }
    })

    local before_right = Clip.load(layout.clips.v1_right.id, layout.db)

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", -15)  -- Try to shrink by 15 frames

    local result = command_manager.execute(cmd)
    assert(result.success, "Trim beyond duration should succeed (deletes clip)")

    local after = Clip.load_optional(layout.clips.v1_left.id, layout.db)
    assert(after == nil, "Clip trimmed beyond its duration should be DELETED")

    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    assert(after_right.timeline_start == before_right.timeline_start - 10,
        string.format("Downstream clip should ripple left by 10 frames (full clip), got %d", after_right.timeline_start))

    layout:cleanup()
end

-- Test 3: Single-frame clip trim by 1 DELETES the clip
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
    cmd:set_parameter("delta_frames", -1)  -- Shrink by 1 frame

    local result = command_manager.execute(cmd)
    assert(result.success, "Trim single-frame clip to zero should succeed (deletes)")

    local after = Clip.load_optional(layout.clips.v1_left.id, layout.db)
    assert(after == nil, "Single-frame clip trimmed to zero should be DELETED")

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

-- Test 6: Roll edit can DELETE a clip when rolled to zero (with media headroom)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_roll_delete.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 5},  -- 5 frames
            v1_right = {timeline_start = 5, duration = 1000, source_in = 100}  -- Has headroom to extend left
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id, trim_type = "roll"},
        {clip_id = layout.clips.v1_right.id, edge_type = "in", track_id = layout.tracks.v1.id, trim_type = "roll"}
    })
    cmd:set_parameter("delta_frames", -5)  -- Roll left by 5 frames (deletes left clip)

    local result = command_manager.execute(cmd)
    assert(result.success, "Roll that deletes clip should succeed")

    local after_left = Clip.load_optional(layout.clips.v1_left.id, layout.db)
    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)

    assert(after_left == nil, "Left clip rolled to zero should be DELETED")
    assert(after_right.duration == 1005,
        string.format("Right clip should extend by 5 frames, got %d", after_right.duration))
    assert(after_right.timeline_start == 0,
        string.format("Right clip should roll to start at 0, got %d", after_right.timeline_start))

    layout:cleanup()
end

print("✅ Zero duration clips are deleted (no negative durations allowed)")
