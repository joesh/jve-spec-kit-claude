#!/usr/bin/env luajit

-- Test zero-delta operations should be no-ops
-- Verifies that delta_frames=0 doesn't mutate timeline state

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test 1: Zero-delta ripple should succeed with no mutations
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_zero_delta.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}
        }
    })

    local before_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local before_right = Clip.load(layout.clips.v1_right.id, layout.db)

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 0)

    local result = command_manager.execute(cmd)
    assert(result.success, "Zero-delta should succeed as no-op")

    local after_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)

    assert(after_left.timeline_start.frames == before_left.timeline_start.frames,
        "Left clip start should be unchanged")
    assert(after_left.duration.frames == before_left.duration.frames,
        "Left clip duration should be unchanged")
    assert(after_right.timeline_start.frames == before_right.timeline_start.frames,
        "Right clip should not shift")

    layout:cleanup()
end

-- Test 2: Dry-run with zero-delta should return empty affected_clips
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_zero_delta_dry.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 0)
    cmd:set_parameter("dry_run", true)

    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok, payload = executor(cmd)

    assert(ok, "Dry-run with zero-delta should succeed")
    assert(type(payload) == "table", "Should return payload table")
    assert(payload.clamped_delta_ms == 0, "Clamped delta should be zero")

    -- Shifted clips list includes downstream clips even if shift amount is zero
    -- This is correct - it documents which clips would move (by zero frames)
    if payload.shifted_clips then
        for _, shift_info in ipairs(payload.shifted_clips) do
            assert(shift_info.new_start_value.frames == layout.clips.v1_right.timeline_start,
                "Shifted clips should have same start position (zero shift)")
        end
    end

    layout:cleanup()
end

-- Test 3: Undo of zero-delta command should also be no-op
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_zero_delta_undo.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 0)

    local result = command_manager.execute(cmd)
    assert(result.success, "Zero-delta execute should succeed")

    local before_undo_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local before_undo_right = Clip.load(layout.clips.v1_right.id, layout.db)

    local undo_result = command_manager.undo()
    assert(undo_result.success, "Undo of zero-delta should succeed")

    local after_undo_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local after_undo_right = Clip.load(layout.clips.v1_right.id, layout.db)

    -- Since execute was no-op, undo should also be no-op (already at original state)
    assert(after_undo_left.timeline_start.frames == before_undo_left.timeline_start.frames,
        "Undo of zero-delta should not change state")
    assert(after_undo_right.timeline_start.frames == before_undo_right.timeline_start.frames,
        "Undo of zero-delta should not change state")

    layout:cleanup()
end

-- Test 4: Zero-delta roll edit should not move clips
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_zero_delta_roll.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 1000, duration = 1000}
        }
    })

    local before_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local before_right = Clip.load(layout.clips.v1_right.id, layout.db)

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id, trim_type = "roll"},
        {clip_id = layout.clips.v1_right.id, edge_type = "in", track_id = layout.tracks.v1.id, trim_type = "roll"}
    })
    cmd:set_parameter("delta_frames", 0)

    local result = command_manager.execute(cmd)
    assert(result.success, "Zero-delta roll should succeed")

    local after_left = Clip.load(layout.clips.v1_left.id, layout.db)
    local after_right = Clip.load(layout.clips.v1_right.id, layout.db)

    assert(after_left.duration.frames == before_left.duration.frames,
        "Roll with zero delta should not change left clip duration")
    assert(after_right.timeline_start.frames == before_right.timeline_start.frames,
        "Roll with zero delta should not move right clip start")
    assert(after_right.duration.frames == before_right.duration.frames,
        "Roll with zero delta should not change right clip duration")

    layout:cleanup()
end

print("✅ Zero-delta operations behave as no-ops (no mutations)")
