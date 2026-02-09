#!/usr/bin/env luajit

-- Test concurrent BatchRippleEdit commands and transaction isolation
-- NOTE: These tests document expected behavior but may not fully exercise concurrency
-- due to LuaJIT's single-threaded nature. They validate sequential consistency.

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test 1: Sequential commands on same clips maintain consistency
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_sequential.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}
        }
    })

    -- First command: extend left clip
    local cmd1 = Command.create("BatchRippleEdit", layout.project_id)
    cmd1:set_parameter("sequence_id", layout.sequence_id)
    cmd1:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd1:set_parameter("delta_frames", 300)

    local result1 = command_manager.execute(cmd1)
    assert(result1.success, "First command should succeed")

    -- Second command: extend same clip again
    local cmd2 = Command.create("BatchRippleEdit", layout.project_id)
    cmd2:set_parameter("sequence_id", layout.sequence_id)
    cmd2:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd2:set_parameter("delta_frames", 200)

    local result2 = command_manager.execute(cmd2)
    assert(result2.success, "Second command should succeed")

    -- Verify cumulative effect
    local after = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(after.duration == 1500,
        string.format("Should have cumulative effect (300+200=500 frames), got duration=%d", after.duration))

    -- Verify downstream clip shifted twice
    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)
    assert(after_right.timeline_start == 2500,
        string.format("Right clip should shift by total (500 frames), got start=%d", after_right.timeline_start))

    layout:cleanup()
end

-- Test 2: Sequential commands on different tracks have cumulative cross-track effects
-- Ripple operations affect ALL downstream clips across ALL tracks (not per-track)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_multi_track.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000},
            v2 = {timeline_start = 0, duration = 1500},
            v2_right = {timeline_start = 2500, duration = 800}
        }
    })

    -- Command on V1
    local cmd1 = Command.create("BatchRippleEdit", layout.project_id)
    cmd1:set_parameter("sequence_id", layout.sequence_id)
    cmd1:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd1:set_parameter("delta_frames", 400)

    local result1 = command_manager.execute(cmd1)
    assert(result1.success, "V1 command should succeed")

    -- Command on V2
    local cmd2 = Command.create("BatchRippleEdit", layout.project_id)
    cmd2:set_parameter("sequence_id", layout.sequence_id)
    cmd2:set_parameter("edge_infos", {
        {clip_id = layout.clips.v2.id, edge_type = "out", track_id = layout.tracks.v2.id}
    })
    cmd2:set_parameter("delta_frames", 300)

    local result2 = command_manager.execute(cmd2)
    assert(result2.success, "V2 command should succeed")

    -- Ripple shifts affect ALL tracks (cross-track ripple per Bug #3 fix)
    local v1_after = Clip.load(layout.clips.v1_right.id, layout.db)
    local v2_after = Clip.load(layout.clips.v2_right.id, layout.db)

    -- V1 command shifted all downstream clips by 400, then V2 command shifted all by 300
    -- v1_right: 2000 + 400 + 300 = 2700
    -- v2_right: 2500 + 400 + 300 = 3200
    assert(v1_after.timeline_start == 2700,
        string.format("V1 right should shift by both ripples (400+300=700), got %d", v1_after.timeline_start))
    assert(v2_after.timeline_start == 3200,
        string.format("V2 right should shift by both ripples (400+300=700), got %d", v2_after.timeline_start))

    layout:cleanup()
end

-- Test 3: Trim beyond duration deletes clip (clamps to zero)
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_rollback.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 10}  -- Tiny clip
        }
    })

    local before_right = Clip.load(layout.clips.v1_right.id, layout.db)

    -- Command clamps when trim would go past zero (deletes clip)
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", -20)  -- Would make duration negative, clamps to zero (delete)

    local result = command_manager.execute(cmd)
    assert(result.success, "Command should succeed (delta clamps to delete clip)")

    -- Clip should be deleted (trimmed to zero)
    local after = Clip.load_optional(layout.clips.v1_left.id, layout.db)
    assert(after == nil, "Clip trimmed beyond duration should be DELETED")

    local right_after = Clip.load(layout.clips.v1_right.id, layout.db)
    assert(right_after.timeline_start == before_right.timeline_start - 10,
        string.format("Downstream clip should ripple left by 10 frames (full clip), got %d", right_after.timeline_start))

    layout:cleanup()
end

-- Test 4: Undo of one command doesn't affect other commands
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_undo_isolation.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}
        }
    })

    -- Execute two commands
    local cmd1 = Command.create("BatchRippleEdit", layout.project_id)
    cmd1:set_parameter("sequence_id", layout.sequence_id)
    cmd1:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd1:set_parameter("delta_frames", 300)
    command_manager.execute(cmd1)

    local cmd2 = Command.create("BatchRippleEdit", layout.project_id)
    cmd2:set_parameter("sequence_id", layout.sequence_id)
    cmd2:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd2:set_parameter("delta_frames", 200)
    command_manager.execute(cmd2)

    -- Undo only the second command
    local undo_result = command_manager.undo()
    assert(undo_result.success, "Undo should succeed")

    -- First command effect should remain
    local after = Clip.load(layout.clips.v1_left.id, layout.db)
    assert(after.duration == 1300,
        string.format("Should only undo second command (300 remains), got duration=%d", after.duration))

    layout:cleanup()
end

-- Test 5: Database integrity after multiple rapid operations
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_integrity.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_middle = {timeline_start = 1500, duration = 500},
            v1_right = {timeline_start = 2500, duration = 1000}
        }
    })

    -- Execute multiple operations rapidly
    for i = 1, 5 do
        local cmd = Command.create("BatchRippleEdit", layout.project_id)
        cmd:set_parameter("sequence_id", layout.sequence_id)
        cmd:set_parameter("edge_infos", {
            {clip_id = layout.clips.v1_middle.id, edge_type = "out", track_id = layout.tracks.v1.id}
        })
        cmd:set_parameter("delta_frames", 50)

        local result = command_manager.execute(cmd)
        assert(result.success, string.format("Operation %d should succeed", i))
    end

    -- Verify final state is consistent (no overlaps)
    local left = Clip.load(layout.clips.v1_left.id, layout.db)
    local middle = Clip.load(layout.clips.v1_middle.id, layout.db)
    local right = Clip.load(layout.clips.v1_right.id, layout.db)

    local left_end = left.timeline_start + left.duration
    local middle_end = middle.timeline_start + middle.duration

    assert(middle.timeline_start >= left_end,
        string.format("Middle clip should not overlap left (left ends at %d, middle starts at %d)",
            left_end, middle.timeline_start))
    assert(right.timeline_start >= middle_end,
        string.format("Right clip should not overlap middle (middle ends at %d, right starts at %d)",
            middle_end, right.timeline_start))

    -- Middle should have grown by 5*50=250 frames
    assert(middle.duration == 750,
        string.format("Middle clip should grow by 250 frames, got duration=%d", middle.duration))

    layout:cleanup()
end

print("✅ Concurrent/sequential command execution maintains database consistency")
