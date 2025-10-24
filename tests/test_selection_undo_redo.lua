#!/usr/bin/env luajit

-- Verifies that clip selection is restored correctly across
-- multiple undo/redo operations so that the command stream
-- remains idempotent.
--
-- Scenario:
--   1. Execute a command that sets selection to Clip A.
--   2. User manually changes selection to Clip B (no command logged).
--   3. Execute a second command that depends on Clip B being selected.
--   4. Undo twice, then redo twice.
-- Expectation:
--   After the first redo, selection should already be Clip B so that
--   the second redo (or command replay) sees the exact same context
--   that existed originally.

package.path = package.path .. ";../src/lua/?.lua;../src/lua/core/?.lua;../src/lua/models/?.lua;../src/lua/ui/?.lua;../src/lua/ui/timeline/?.lua;../tests/?.lua"

require('test_env')

-- Mock timeline_state to avoid pulling in Qt bindings.
local mock_timeline_state = {
    playhead_time = 0,
    clips = {},
    selected_clips = {},
    selected_edges = {},
    selection_log = {}
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

local function log_selection(clips)
    local ids = {}
    for _, clip in ipairs(clips or {}) do
        table.insert(ids, clip.id)
    end
    table.insert(mock_timeline_state.selection_log, table.concat(ids, ","))
end

function mock_timeline_state.set_selection(clips)
    mock_timeline_state.selected_clips = clips or {}
    mock_timeline_state.selected_edges = {}
    log_selection(mock_timeline_state.selected_clips)
end

function mock_timeline_state.get_selected_edges()
    return mock_timeline_state.selected_edges
end

function mock_timeline_state.set_edge_selection(edges)
    mock_timeline_state.selected_edges = edges or {}
    mock_timeline_state.selected_clips = {}
    log_selection(mock_timeline_state.selected_clips)
end

function mock_timeline_state.reload_clips()
    -- No-op for tests.
end

function mock_timeline_state.persist_state_to_db()
    -- Not needed for this isolated test.
end

package.loaded['ui.timeline.timeline_state'] = mock_timeline_state

local command_manager = require('core.command_manager')
local Command = require('command')
local database = require('core.database')

print("=== Selection Undo/Redo Tests ===\n")

-- Set up isolated database backing the CommandManager.
local test_db_path = "/tmp/test_selection_undo_redo.db"
os.remove(test_db_path)

database.init(test_db_path)
local db = database.get_connection()

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
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
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

db:exec([[
    INSERT INTO projects (id, name) VALUES ('test_project', 'Test Project');
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('test_sequence', 'test_project', 'Test Sequence', 30.0, 1920, 1080);
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
    VALUES ('track_test_v1', 'test_sequence', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, track_type, track_index, enabled)
    VALUES ('track_default_v1', 'default_sequence', 'VIDEO', 1, 1);
    INSERT INTO media (id, project_id, file_path, name)
    VALUES ('media_clip', 'test_project', '/tmp/media_clip.mov', 'Test Clip');
    INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip0', 'track_test_v1', 'media_clip', 0, 1000, 0, 1000, 1);
    INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip1', 'track_test_v1', 'media_clip', 2000, 1000, 0, 1000, 1);
    INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip2', 'track_test_v1', 'media_clip', 4000, 1000, 0, 1000, 1);
]])

command_manager.init(db, 'test_sequence', 'test_project')

-- Provide lightweight command executors used only by this test.
command_manager.register_executor("TestSelectClip", function(command)
    local clip_id = command:get_parameter("clip_id")
    local timeline_state = require('ui.timeline.timeline_state')
    timeline_state.set_selection({{id = clip_id}})
    return true
end)

command_manager.register_executor("TestNoOp", function()
    return true
end)

local timeline_state = require('ui.timeline.timeline_state')

local function current_selection()
    local clips = timeline_state.get_selected_clips() or {}
    local ids = {}
    for _, clip in ipairs(clips) do
        table.insert(ids, clip.id)
    end
    return table.concat(ids, ",")
end

local function assert_selection(expected, context)
    local actual = current_selection()
    if actual ~= expected then
        print(string.format("❌ FAIL: %s\nExpected selection: %s\nActual selection:   %s", context, expected, actual))
        os.exit(1)
    else
        print(string.format("✅ PASS: %s (%s)", context, expected))
    end
end

-- Initial state mirrors a user with Clip 0 selected.
timeline_state.set_selection({{id = "clip0"}})
assert_selection("clip0", "Initial selection")

-- Command 1 sets selection to Clip 1.
local cmd1 = Command.create("TestSelectClip", "test_project")
cmd1:set_parameter("clip_id", "clip1")
local result1 = command_manager.execute(cmd1)
if not result1.success then
    print("❌ FAIL: Command 1 execution failed: " .. tostring(result1.error_message))
    os.exit(1)
end
assert_selection("clip1", "After command 1")

-- User manually changes selection to Clip 2 (outside of command system).
timeline_state.set_selection({{id = "clip2"}})
assert_selection("clip2", "Manual selection change before command 2")

-- Command 2 records the current selection but does not mutate it.
local cmd2 = Command.create("TestNoOp", "test_project")
local result2 = command_manager.execute(cmd2)
if not result2.success then
    print("❌ FAIL: Command 2 execution failed: " .. tostring(result2.error_message))
    os.exit(1)
end
assert_selection("clip2", "After command 2")

-- Undo twice: should return to initial selection.
command_manager.undo()
assert_selection("clip2", "After undoing command 2 (restores pre-state)")
command_manager.undo()
assert_selection("clip0", "After undoing command 1")

-- Redo command 1.
command_manager.redo()
assert_selection("clip2", "After redoing command 1 (should match next command pre-state)")

-- Redo command 2.
command_manager.redo()
assert_selection("clip2", "After redoing command 2 (head state)")

command_manager.unregister_executor("TestSelectClip")
command_manager.unregister_executor("TestNoOp")

print("\nAll selection undo/redo assertions passed.")
