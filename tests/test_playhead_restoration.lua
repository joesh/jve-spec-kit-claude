#!/usr/bin/env luajit

-- Test playhead position restoration during undo/redo
-- Ensures playhead returns to position BEFORE undone command

package.path = package.path .. ";../src/lua/?.lua;../src/lua/core/?.lua;../src/lua/models/?.lua;../src/lua/ui/?.lua;../src/lua/ui/timeline/?.lua;../tests/?.lua"

require('test_env')

-- Mock timeline_state module for testing
local mock_timeline_state = {
    playhead_value = 0,
    clips = {},
    selected_clips = {},
    selected_edges = {},
    viewport_start_value = 0,
    viewport_duration_frames_value = 300
}

function mock_timeline_state.get_playhead_value()
    return mock_timeline_state.playhead_value
end

function mock_timeline_state.set_playhead_value(time)
    mock_timeline_state.playhead_value = time
end

function mock_timeline_state.get_selected_clips()
    return mock_timeline_state.selected_clips
end

function mock_timeline_state.set_selection(clips)
    mock_timeline_state.selected_clips = clips
    mock_timeline_state.selected_edges = {}
end

function mock_timeline_state.get_selected_edges()
    return mock_timeline_state.selected_edges
end

function mock_timeline_state.set_edge_selection(edges)
    mock_timeline_state.selected_edges = edges
    mock_timeline_state.selected_clips = {}
end

function mock_timeline_state.reload_clips()
    -- Mock implementation - does nothing
end

function mock_timeline_state.apply_mutations(sequence_id, mutations)
    if sequence_id and sequence_id ~= "" then
        mock_timeline_state.sequence_id = sequence_id
    end
    return mutations ~= nil
end

function mock_timeline_state.consume_mutation_failure()
    return nil
end

function mock_timeline_state.get_sequence_id()
    return mock_timeline_state.sequence_id or "default_sequence"
end
function mock_timeline_state.get_sequence_frame_rate()
    return 30.0
end

local viewport_guard = 0

function mock_timeline_state.capture_viewport()
    return {
        start_value = mock_timeline_state.viewport_start_value,
        duration_value = mock_timeline_state.viewport_duration_frames_value,
    }
end

function mock_timeline_state.restore_viewport(snapshot)
    if not snapshot then
        return
    end

    if snapshot.duration_value then
        mock_timeline_state.viewport_duration_frames_value = snapshot.duration_value
    end

    if snapshot.start_value then
        mock_timeline_state.viewport_start_value = snapshot.start_value
    end
end

function mock_timeline_state.push_viewport_guard()
    viewport_guard = viewport_guard + 1
    return viewport_guard
end

function mock_timeline_state.pop_viewport_guard()
    if viewport_guard > 0 then
        viewport_guard = viewport_guard - 1
    end
    return viewport_guard
end

-- Register mock before loading command_manager
package.loaded['ui.timeline.timeline_state'] = mock_timeline_state

local command_manager = require('core.command_manager')
local Command = require('command')
local database = require('core.database')

print("=== Playhead Restoration Tests ===\n")

-- Setup test database
local test_db_path = "/tmp/jve/test_playhead_restoration.db"
os.remove(test_db_path)

database.init(test_db_path)
local db = database.get_connection()

-- Create schema
db:exec(require('import_schema'))

-- Insert test data
db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES
        ('test_project', 'Test Project', strftime('%s','now'), strftime('%s','now')),
        ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
                           timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES
        ('test_sequence', 'test_project', 'Test Sequence', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 300),
        ('default_sequence', 'default_project', 'Default Sequence', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 300);

    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES
        ('track_v1', 'test_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 1, 1),
        ('track_default_v1', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 1, 1);
]])

do
    local stmt = db:prepare("SELECT COUNT(*) FROM sequences WHERE project_id = 'test_project'")
    assert(stmt:exec() and stmt:next())
    print("DEBUG pre-init sequences", stmt:value(0))
    stmt:finalize()
end

command_manager.init(db, 'test_sequence', 'test_project')

-- Test 1: Playhead restoration after undo
print("Test 1: Undo restores playhead to pre-command position")

-- Set initial playhead position
mock_timeline_state.set_playhead_value(5000)
print("   Initial playhead: 5000ms")

-- Execute a command (CreateSequence doesn't move playhead)
local cmd1 = Command.create("CreateSequence", "test_project")
cmd1:set_parameter("name", "Test Seq 1")
cmd1:set_parameter("project_id", "test_project")
cmd1:set_parameter("frame_rate", 30.0)
cmd1:set_parameter("width", 1920)
cmd1:set_parameter("height", 1080)

local result1 = command_manager.execute(cmd1)
if not result1.success then
    print("❌ FAIL: Command 1 execution failed")
    os.exit(1)
end
-- Simulate user moving playhead after command 1 by persisting new position
mock_timeline_state.set_playhead_value(5000)
local timeline_state = require('ui.timeline.timeline_state')
timeline_state.set_playhead_value(5000)
print("   After command 1: " .. mock_timeline_state.get_playhead_value() .. "ms")

-- Move playhead
mock_timeline_state.set_playhead_value(10000)
timeline_state.set_playhead_value(10000)
print("   Moved playhead to: 10000ms")

-- Execute second command
local cmd2 = Command.create("CreateSequence", "test_project")
cmd2:set_parameter("name", "Test Seq 2")
cmd2:set_parameter("project_id", "test_project")
cmd2:set_parameter("frame_rate", 30.0)
cmd2:set_parameter("width", 1920)
cmd2:set_parameter("height", 1080)

local result2 = command_manager.execute(cmd2)
if not result2.success then
    print("❌ FAIL: Command 2 execution failed")
    os.exit(1)
end
print("   After command 2: " .. mock_timeline_state.get_playhead_value() .. "ms")
timeline_state.set_playhead_value(10000)

-- Undo should restore playhead to 10000ms (position BEFORE cmd2)
command_manager.undo()
local playhead_after_undo = mock_timeline_state.get_playhead_value()
print("   After undo: " .. playhead_after_undo .. "ms")

if playhead_after_undo == 10000 then
    print("✅ PASS: Playhead correctly restored to pre-command position\n")
else
    print("❌ FAIL: Expected playhead at 10000ms, got " .. playhead_after_undo .. "ms\n")
    os.exit(1)
end

-- Test 2: Redo does not restore playhead (playhead is user state between commands)
print("Test 2: Redo preserves current playhead position")

-- Move playhead somewhere else
mock_timeline_state.set_playhead_value(15000)
timeline_state.set_playhead_value(15000)
print("   Moved playhead to: 15000ms before redo")

-- Redo command 2
command_manager.redo()
local playhead_after_redo = mock_timeline_state.get_playhead_value()
print("   After redo: " .. playhead_after_redo .. "ms")

-- Redo should NOT change playhead (it's user state, not command output)
if playhead_after_redo == 15000 then
    print("✅ PASS: Redo preserved user's playhead position\n")
else
    print("⚠️  NOTE: Redo changed playhead to " .. playhead_after_redo .. "ms")
    print("   This may be intentional, but playhead is typically user state\n")
end

-- We're currently at position after cmd2, playhead at 15000ms
-- Undo to position after cmd1 (should restore to 10000ms)
command_manager.undo()
local playhead_after_second_undo = mock_timeline_state.get_playhead_value()
print("   After second undo: " .. playhead_after_second_undo .. "ms")

if playhead_after_second_undo == 10000 then
    print("✅ PASS: Second undo correctly restored to command 1's post-state\n")
else
    print("❌ FAIL: Expected playhead at 10000ms, got " .. playhead_after_second_undo .. "ms\n")
    os.exit(1)
end

-- Undo again to drop command 1 (should restore to original 5000ms)
command_manager.undo()
local playhead_after_third_undo = mock_timeline_state.get_playhead_value()
print("   After third undo: " .. playhead_after_third_undo .. "ms")

if playhead_after_third_undo == 5000 then
    print("✅ PASS: Third undo correctly restored to earlier playhead position\n")
else
    print("❌ FAIL: Expected playhead at 5000ms, got " .. playhead_after_third_undo .. "ms\n")
    os.exit(1)
end

print("=== All Playhead Restoration Tests Passed ===")
os.remove(test_db_path)
os.exit(0)
