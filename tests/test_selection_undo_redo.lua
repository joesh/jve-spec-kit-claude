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
    selection_log = {},
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

package.loaded['ui.timeline.timeline_state'] = mock_timeline_state

local command_manager = require('core.command_manager')
local Clip = require('models.clip')
local _original_clip_load_optional = Clip.load_optional
local clip_catalog = { clip0 = true, clip1 = true, clip2 = true }
Clip.load_optional = function(clip_id)
    if not clip_id then
        return nil
    end
    if clip_catalog[clip_id] then
        return { id = clip_id, clip_kind = 'timeline', owner_sequence_id = 'test_sequence' }
    end
    return _original_clip_load_optional(clip_id)
end

local Command = require('command')
local database = require('core.database')
local Media = require('models.media')

print("=== Selection Undo/Redo Tests ===\n")

-- Set up isolated database backing the CommandManager.
local test_db_path = "/tmp/jve/test_selection_undo_redo.db"
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
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        viewport_start_time INTEGER NOT NULL DEFAULT 0,
        viewport_duration INTEGER NOT NULL DEFAULT 10000,
        mark_in_time INTEGER,
        mark_out_time INTEGER,
        current_sequence_number INTEGER
    );

    CREATE TABLE IF NOT EXISTS tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
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
        duration INTEGER NOT NULL DEFAULT 0,
        frame_rate REAL NOT NULL DEFAULT 0,
        width INTEGER NOT NULL DEFAULT 0,
        height INTEGER NOT NULL DEFAULT 0,
        audio_channels INTEGER NOT NULL DEFAULT 0,
        codec TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0,
        metadata TEXT NOT NULL DEFAULT '{}'
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
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_test_v1', 'test_sequence', 'Track', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('track_default_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1);
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES ('media_clip', 'test_project', 'Test Clip', '/tmp/jve/media_clip.mov', 1000, 30.0, 1920, 1080, 2, 'prores', 0, 0, '{}');
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip0', 'test_project', 'timeline', '', 'track_test_v1', 'media_clip', 'test_sequence', 0, 1000, 0, 1000, 1);
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip1', 'test_project', 'timeline', '', 'track_test_v1', 'media_clip', 'test_sequence', 2000, 1000, 0, 1000, 1);
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id, start_time, duration, source_in, source_out, enabled)
    VALUES ('clip2', 'test_project', 'timeline', '', 'track_test_v1', 'media_clip', 'test_sequence', 4000, 1000, 0, 1000, 1);
]])

command_manager.init(db, 'test_sequence', 'test_project')

command_manager.register_executor("TestEnsureMedia", function(cmd)
    local media = Media.create({
        id = cmd:get_parameter("media_id"),
        project_id = cmd:get_parameter("project_id") or 'test_project',
        file_path = cmd:get_parameter("file_path"),
        file_name = cmd:get_parameter("file_name"),
        name = cmd:get_parameter("file_name"),
        duration = cmd:get_parameter("duration") or 1000,
        frame_rate = cmd:get_parameter("frame_rate") or 30
    })
    assert(media, "failed to create media " .. tostring(cmd:get_parameter("media_id")))
    return media:save(db)
end)

local ensure_media_cmd = Command.create("TestEnsureMedia", "test_project")
ensure_media_cmd:set_parameter("media_id", "media_clip")
ensure_media_cmd:set_parameter("file_path", "/tmp/jve/media_clip.mov")
ensure_media_cmd:set_parameter("file_name", "Test Clip")
ensure_media_cmd:set_parameter("duration", 1000)
ensure_media_cmd:set_parameter("frame_rate", 30)
assert(command_manager.execute(ensure_media_cmd).success)

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

-- Regression: redo gracefully handles missing selection clips
print("\nTest 4: Redo skips missing selection clips")
mock_timeline_state.selection_log = {}

local select_clip0 = Command.create("TestSelectClip", "test_project")
select_clip0:set_parameter("clip_id", "clip0")
assert(command_manager.execute(select_clip0).success, "Selecting clip0 should succeed")

local noop_cmd = Command.create("TestNoOp", "test_project")
assert(command_manager.execute(noop_cmd).success, "Executing no-op command should succeed")

assert(db:exec("DELETE FROM clips WHERE id = 'clip0'"), "Failed to delete clip0 from database")
clip_catalog["clip0"] = nil

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo after deleting clip should succeed")

local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed even if selection clip was deleted")

local last_log_entry = mock_timeline_state.selection_log[#mock_timeline_state.selection_log] or ""
assert(last_log_entry == "", string.format("Selection after redo should be empty, got '%s'", last_log_entry))

print("✅ Redo gracefully handles missing selection clips")

command_manager.unregister_executor("TestSelectClip")
command_manager.unregister_executor("TestNoOp")

print("\nAll selection undo/redo assertions passed.")
