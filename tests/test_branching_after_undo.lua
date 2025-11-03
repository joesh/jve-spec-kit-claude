#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')
local Command = require('command')

local function stub_timeline_state()
    timeline_state.capture_viewport = function()
        return {start_time = 0, duration = 10000}
    end
    timeline_state.push_viewport_guard = function() end
    timeline_state.pop_viewport_guard = function() end
    timeline_state.restore_viewport = function(_) end
    timeline_state.set_selection = function(_) end
    timeline_state.set_edge_selection = function(_) end
    timeline_state.set_gap_selection = function(_) end
    timeline_state.get_selected_clips = function() return {} end
    timeline_state.get_selected_edges = function() return {} end
    timeline_state.set_playhead_time = function(_) end
    timeline_state.get_playhead_time = function() return 0 end
    timeline_state.get_project_id = function() return 'default_project' end
    timeline_state.get_sequence_id = function() return 'default_sequence' end
    timeline_state.reload_clips = function() end
end

local function init_db(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db)

    local schema = [[
        CREATE TABLE projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at INTEGER,
            modified_at INTEGER,
            settings TEXT DEFAULT '{}'
        );

        CREATE TABLE sequences (
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

        CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            sequence_id TEXT NOT NULL,
            name TEXT NOT NULL,
            track_type TEXT NOT NULL,
            track_index INTEGER NOT NULL
        );

        CREATE TABLE commands (
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
            selected_gap_infos TEXT DEFAULT '[]',
            selected_clip_ids_pre TEXT DEFAULT '[]',
            selected_edge_infos_pre TEXT DEFAULT '[]',
            selected_gap_infos_pre TEXT DEFAULT '[]'
        );
    ]]

    local ok, err = db:exec(schema)
    assert(ok, err)

    ok, err = db:exec([[INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');]])
    assert(ok, err)
    ok, err = db:exec([[INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
                        VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);]])
    assert(ok, err)
    ok, err = db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
                        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1);]])
    assert(ok, err)

    return db
end

local executed_labels = {}

local function register_test_command()
    command_manager.register_executor("TestOp", function(command)
        local label = command:get_parameter("label") or "?"
        table.insert(executed_labels, label)
        return true
    end)
end

local function reset_log()
    for i = #executed_labels, 1, -1 do
        executed_labels[i] = nil
    end
end

stub_timeline_state()
local db_path = "/tmp/test_branching_after_undo.db"
init_db(db_path)

register_test_command()
command_manager.init(database.get_connection(), 'default_sequence', 'default_project')

-- Execute initial command (acts like the XML import)
reset_log()
local import_cmd = Command.create("TestOp", "default_project")
import_cmd:set_parameter("label", "import")
assert(command_manager.execute(import_cmd).success)
assert(#executed_labels == 1 and executed_labels[1] == "import", "Initial command should run")

-- Undo to root
assert(command_manager.undo().success, "Undo to root should succeed")
reset_log()

-- Execute new command after undo (acts like importing a clip)
reset_log()
local clip_cmd = Command.create("TestOp", "default_project")
clip_cmd:set_parameter("label", "clip")
assert(command_manager.execute(clip_cmd).success)
assert(#executed_labels == 1 and executed_labels[1] == "clip", "New command should run")

assert(command_manager.undo().success, "Undo new command should succeed")
reset_log()

-- Redo should replay only the new command (clip) and NOT the original import
reset_log()
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed")
assert(#executed_labels == 1 and executed_labels[1] == "clip", "Redo should replay the new branch only")

-- No further redo should be available
local redo_again = command_manager.redo()
assert(not redo_again.success, "Redo should be exhausted after replaying new branch")

print("✅ Branching after undo test passed")
