#!/usr/bin/env luajit

-- Test pure gap-to-gap operations (no clip edges selected)
-- Validates that gaps behave like first-class timeline items per Rule 1-2

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test 1: Pure gap_after ripple (single gap edge, no clips)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_pure_gap_after.db",
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
    cmd:set_parameter("delta_frames", 300)  -- Close gap by 300 frames

    local result = command_manager.execute(cmd)
    assert(result.success, "Pure gap_after ripple should succeed")

    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    assert(after_right.timeline_start.frames == 1700,
        string.format("Right clip should shift left by 300, got %d", after_right.timeline_start.frames))

    layout:cleanup()
end

-- Test 2: Pure gap_before ripple (single gap edge, no clips)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_pure_gap_before.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2500, duration = 1000}  -- 1500 frame gap
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_right.id, edge_type = "gap_before", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", -400)  -- Close gap from right side

    local result = command_manager.execute(cmd)
    assert(result.success, "Pure gap_before ripple should succeed")

    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    assert(after_right.timeline_start.frames == 2100,
        string.format("Right clip should shift left by 400, got %d", after_right.timeline_start.frames))

    layout:cleanup()
end

-- Test 3: gap_after + gap_before roll (both sides of same gap, like clip roll)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_gap_gap_roll.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000},  -- 1000 frame gap
            v1_downstream = {timeline_start = 4000, duration = 500}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "gap_after", track_id = layout.tracks.v1.id, trim_type = "roll"},
        {clip_id = layout.clips.v1_right.id, edge_type = "gap_before", track_id = layout.tracks.v1.id, trim_type = "roll"}
    })
    cmd:set_parameter("delta_frames", 200)  -- Shift gap boundary right

    local result = command_manager.execute(cmd)
    assert(result.success, "Gap-to-gap roll should succeed")

    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    local after_downstream = Clip.load(layout.clips.v1_downstream.id, layout.db)

    -- Roll: right clip moves, but downstream should NOT shift (timeline length unchanged)
    assert(after_right.timeline_start.frames == 2200,
        string.format("Right clip should move right by 200 (roll), got %d", after_right.timeline_start.frames))
    assert(after_downstream.timeline_start.frames == 4000,
        string.format("Downstream clip should NOT shift in roll, got %d", after_downstream.timeline_start.frames))

    layout:cleanup()
end

-- Test 4: Multiple gap_after edges across tracks (multi-track gap ripple)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_multi_gap_sync.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000},  -- V1 gap = 1000
            v2 = {timeline_start = 1500, duration = 800},
            v2_right = {timeline_start = 3000, duration = 500}   -- V2 gap = 700
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "gap_after", track_id = layout.tracks.v1.id},
        {clip_id = layout.clips.v2.id, edge_type = "gap_after", track_id = layout.tracks.v2.id}
    })
    cmd:set_parameter("delta_frames", 900)  -- Try to close both gaps

    local result = command_manager.execute(cmd)
    assert(result.success, "Multi-track gap ripple should succeed")

    local after_v1_right = Clip.load(layout.clips.v1_right.id, layout.db)
    local after_v2_right = Clip.load(layout.clips.v2_right.id, layout.db)

    -- Should clamp to smallest gap (700 frames on V2)
    assert(after_v1_right.timeline_start.frames == 1300,
        string.format("V1 should shift by clamped delta (700), got %d", after_v1_right.timeline_start.frames))
    assert(after_v2_right.timeline_start.frames == 2300,
        string.format("V2 should shift by same clamped delta (700), got %d", after_v2_right.timeline_start.frames))

    layout:cleanup()
end

-- Test 5: gap_after + gap_before on different tracks (asymmetric gap operations)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_cross_track_gaps.db",
        clips = {
            order = {"v1_left", "v1_right", "v2_left", "v2_right"},  -- Exclude default v2 clip
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000},
            v2_left = {timeline_start = 0, duration = 1500},
            v2_right = {timeline_start = 2500, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "gap_after", track_id = layout.tracks.v1.id},
        {clip_id = layout.clips.v2_right.id, edge_type = "gap_before", track_id = layout.tracks.v2.id}
    })
    cmd:set_parameter("delta_frames", 300)

    local result = command_manager.execute(cmd)
    assert(result.success, "Cross-track asymmetric gap operations should succeed")

    -- With cross-track ripple (Bug #3 fix), both operations affect all downstream clips
    local after_v1_right = Clip.load(layout.clips.v1_right.id, layout.db)
    local after_v2_right = Clip.load(layout.clips.v2_right.id, layout.db)

    -- Both clips shift together due to cross-track ripple
    assert(after_v1_right.timeline_start.frames == 1700,
        string.format("V1 right should shift left by 300, got %d", after_v1_right.timeline_start.frames))
    assert(after_v2_right.timeline_start.frames == 2200,
        string.format("V2 right should shift left by 300, got %d", after_v2_right.timeline_start.frames))

    layout:cleanup()
end

print("✅ Pure gap-to-gap operations work correctly (gaps are first-class timeline items)")
