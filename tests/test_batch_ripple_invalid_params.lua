#!/usr/bin/env luajit

-- Negative tests for BatchRippleEdit parameter validation
-- Tests error handling for invalid/missing parameters

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test 1: Invalid edge_type should fail gracefully
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_invalid_edge_type.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "middle", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 100)

    local result = command_manager.execute(cmd)
    assert(not result.success, "Invalid edge_type 'middle' should fail")
    assert(result.error_message and result.error_message:find("edge"),
        "Error message should mention edge_type issue")

    layout:cleanup()
end

-- Test 2: nil edge_type should fail gracefully
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_nil_edge_type.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = nil, track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 100)

    local result = command_manager.execute(cmd)
    assert(not result.success, "nil edge_type should fail")

    layout:cleanup()
end

-- Test 3: Missing clip_id should skip with warning
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_missing_clip_id.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = nil, edge_type = "out", track_id = layout.tracks.v1.id},
        {clip_id = layout.clips.v1_right.id, edge_type = "in", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 100)

    local result = command_manager.execute(cmd)
    assert(result.success, "nil clip_id should be skipped with warning (not fail the command)")

    layout:cleanup()
end

-- Test 4: Non-existent clip_id should skip with warning
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_nonexistent_clip.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = "nonexistent_clip_id_12345", edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_frames", 100)

    local result = command_manager.execute(cmd)
    -- Implementation prints "WARNING: Clip not found. Skipping."
    -- Should still succeed as this is graceful degradation
    assert(result.success, "Non-existent clip should be skipped gracefully, not cause failure")

    layout:cleanup()
end

-- Test 5: Empty edge_infos array should fail with clear error
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_empty_edges.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {})  -- Empty array
    cmd:set_parameter("delta_frames", 100)

    local result = command_manager.execute(cmd)
    assert(not result.success, "Empty edge_infos should fail")
    assert(result.error_message, "Should provide error message for empty edges")

    layout:cleanup()
end

-- Test 6: Missing edge_infos parameter should fail
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_no_edges.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    -- Deliberately omit edge_infos
    cmd:set_parameter("delta_frames", 100)

    local result = command_manager.execute(cmd)
    assert(not result.success, "Missing edge_infos should fail")

    layout:cleanup()
end

-- Test 7: Missing delta parameter should fail
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_no_delta.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    -- Deliberately omit delta_frames and delta_ms

    local result = command_manager.execute(cmd)
    assert(not result.success, "Missing delta should fail")

    layout:cleanup()
end

-- Test 8: Invalid delta_ms type (number instead of Rational) should error
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_invalid_delta_type.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = layout.tracks.v1.id}
    })
    cmd:set_parameter("delta_ms", 100)  -- Plain number, should be Rational

    local result = command_manager.execute(cmd)
    assert(not result.success, "Plain number for delta_ms should fail (must be Rational)")
    assert(result.error_message and result.error_message:find("Rational"),
        "Error should mention Rational type requirement")

    layout:cleanup()
end

print("✅ BatchRippleEdit parameter validation handles all invalid input gracefully")
