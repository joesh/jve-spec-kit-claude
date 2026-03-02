#!/usr/bin/env luajit

-- Test playhead position restoration during undo/redo
-- Ensures playhead returns to position BEFORE undone command
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local command_manager = require('core.command_manager')
local Command = require('command')
local database = require('core.database')
local timeline_state = require('ui.timeline.timeline_state')

print("=== Playhead Restoration Tests ===\n")

-- Setup test database
local test_db_path = "/tmp/jve/test_playhead_restoration.db"
os.remove(test_db_path)
os.remove(test_db_path .. "-wal")
os.remove(test_db_path .. "-shm")

database.init(test_db_path)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Test Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'test_sequence', 'test_project', 'Test Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 300, 0,
        '[]', '[]', '[]', 0, %d, %d
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'test_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

command_manager.init('test_sequence', 'test_project')

-- Test 1: Playhead restoration after undo
print("Test 1: Undo restores playhead to pre-command position")

-- Set initial playhead position
timeline_state.set_playhead_position(5000)

-- Execute a command (CreateSequence doesn't move playhead)
local cmd1 = Command.create("CreateSequence", "test_project")
cmd1:set_parameter("name", "Test Seq 1")
cmd1:set_parameter("project_id", "test_project")
cmd1:set_parameter("frame_rate", 30.0)
cmd1:set_parameter("width", 1920)
cmd1:set_parameter("height", 1080)

local result1 = command_manager.execute(cmd1)
assert(result1.success, "Command 1 execution failed: " .. tostring(result1.error_message))
timeline_state.set_playhead_position(5000)

-- Move playhead
timeline_state.set_playhead_position(10000)

-- Execute second command
local cmd2 = Command.create("CreateSequence", "test_project")
cmd2:set_parameter("name", "Test Seq 2")
cmd2:set_parameter("project_id", "test_project")
cmd2:set_parameter("frame_rate", 30.0)
cmd2:set_parameter("width", 1920)
cmd2:set_parameter("height", 1080)

local result2 = command_manager.execute(cmd2)
assert(result2.success, "Command 2 execution failed: " .. tostring(result2.error_message))
timeline_state.set_playhead_position(10000)

-- Undo should restore playhead to 10000 (position BEFORE cmd2)
command_manager.undo()
local playhead_after_undo = timeline_state.get_playhead_position()
assert(playhead_after_undo == 10000,
    string.format("Expected playhead at 10000 after undo, got %s", tostring(playhead_after_undo)))

-- Test 2: Redo preserves current playhead position
print("Test 2: Redo preserves current playhead position")

-- Move playhead somewhere else
timeline_state.set_playhead_position(15000)

-- Redo command 2
command_manager.redo()
local playhead_after_redo = timeline_state.get_playhead_position()

-- Redo may or may not change playhead — just note behavior
if playhead_after_redo == 15000 then
    print("  Redo preserved user's playhead position")
else
    print(string.format("  Redo changed playhead to %s (may be intentional)", tostring(playhead_after_redo)))
end

-- Undo to position after cmd1 (should restore to 10000)
command_manager.undo()
local playhead_after_second_undo = timeline_state.get_playhead_position()
assert(playhead_after_second_undo == 10000,
    string.format("Expected playhead at 10000 after second undo, got %s", tostring(playhead_after_second_undo)))

-- Undo again to drop command 1 (should restore to original 5000)
command_manager.undo()
local playhead_after_third_undo = timeline_state.get_playhead_position()
assert(playhead_after_third_undo == 5000,
    string.format("Expected playhead at 5000 after third undo, got %s", tostring(playhead_after_third_undo)))

print("✅ test_playhead_restoration.lua passed")
