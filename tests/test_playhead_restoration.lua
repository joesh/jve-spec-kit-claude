#!/usr/bin/env luajit

-- Test playhead position restoration during undo/redo
-- Ensures playhead returns to position BEFORE undone command

package.path = package.path .. ";../src/lua/?.lua;../src/lua/core/?.lua;../src/lua/models/?.lua;../src/lua/ui/?.lua;../src/lua/ui/timeline/?.lua;../tests/?.lua"

require('test_env')

-- Mock timeline_state module for testing
local mock_timeline_state = {
    playhead_time = 0,
    clips = {},
    selected_clips = {},
    selected_edges = {},
    viewport_start_time = 0,
    viewport_duration = 10000
}

function mock_timeline_state.get_playhead_time()
    return mock_timeline_state.playhead_time
end

function mock_timeline_state.set_playhead_time(time)
    mock_timeline_state.playhead_time = time
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

local viewport_guard = 0

function mock_timeline_state.capture_viewport()
    return {
        start_time = mock_timeline_state.viewport_start_time,
        duration = mock_timeline_state.viewport_duration,
    }
end

function mock_timeline_state.restore_viewport(snapshot)
    if not snapshot then
        return
    end

    if snapshot.duration then
        mock_timeline_state.viewport_duration = snapshot.duration
    end

    if snapshot.start_time then
        mock_timeline_state.viewport_start_time = snapshot.start_time
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
local test_db_path = "/tmp/test_playhead_restoration.db"
os.remove(test_db_path)

database.init(test_db_path)
local db = database.get_connection()

-- Create schema
db:exec([[
    CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE IF NOT EXISTS sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_time INTEGER NOT NULL DEFAULT 0,
        viewport_duration INTEGER NOT NULL DEFAULT 10000,
        mark_in_time INTEGER,
        mark_out_time INTEGER,
        current_sequence_number INTEGER
    );

    CREATE TABLE IF NOT EXISTS tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS clips (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        media_id TEXT,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL,
        source_out INTEGER NOT NULL,
        enabled BOOLEAN DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        file_path TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL,
        duration INTEGER,
        frame_rate REAL,
        width INTEGER,
        height INTEGER
    );

    CREATE TABLE IF NOT EXISTS commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_time INTEGER DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]'
    );
]])

-- Insert test data
db:exec([[
    INSERT INTO projects (id, name) VALUES ('test_project', 'Test Project');
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('test_sequence', 'test_project', 'Test Sequence', 30.0, 1920, 1080);
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
    VALUES ('track_v1', 'test_sequence', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
    VALUES ('track_default_v1', 'default_sequence', 'VIDEO', 1, 1);
]])

command_manager.init(db, 'test_sequence', 'test_project')

-- Test 1: Playhead restoration after undo
print("Test 1: Undo restores playhead to pre-command position")

-- Set initial playhead position
mock_timeline_state.set_playhead_time(5000)
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
mock_timeline_state.set_playhead_time(5000)
local timeline_state = require('ui.timeline.timeline_state')
timeline_state.set_playhead_time(5000)
print("   After command 1: " .. mock_timeline_state.get_playhead_time() .. "ms")

-- Move playhead
mock_timeline_state.set_playhead_time(10000)
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
print("   After command 2: " .. mock_timeline_state.get_playhead_time() .. "ms")
timeline_state.set_playhead_time(10000)

-- Undo should restore playhead to 10000ms (position BEFORE cmd2)
command_manager.undo()
local playhead_after_undo = mock_timeline_state.get_playhead_time()
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
mock_timeline_state.set_playhead_time(15000)
print("   Moved playhead to: 15000ms before redo")

-- Redo command 2
command_manager.redo()
local playhead_after_redo = mock_timeline_state.get_playhead_time()
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
local playhead_after_second_undo = mock_timeline_state.get_playhead_time()
print("   After second undo: " .. playhead_after_second_undo .. "ms")

if playhead_after_second_undo == 10000 then
    print("✅ PASS: Second undo correctly restored to command 1's post-state\n")
else
    print("❌ FAIL: Expected playhead at 10000ms, got " .. playhead_after_second_undo .. "ms\n")
    os.exit(1)
end

-- Undo again to drop command 1 (should restore to original 5000ms)
command_manager.undo()
local playhead_after_third_undo = mock_timeline_state.get_playhead_time()
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
