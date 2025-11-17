#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

local function create_schema(db)
    db:exec([[ 
        CREATE TABLE projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
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
            track_index INTEGER NOT NULL,
            enabled BOOLEAN NOT NULL DEFAULT 1,
            locked BOOLEAN NOT NULL DEFAULT 0,
            muted BOOLEAN NOT NULL DEFAULT 0,
            soloed BOOLEAN NOT NULL DEFAULT 0,
            volume REAL NOT NULL DEFAULT 1.0,
            pan REAL NOT NULL DEFAULT 0.0
        );

        CREATE TABLE media (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT,
            file_path TEXT,
            duration INTEGER DEFAULT 0,
            frame_rate REAL DEFAULT 0
        );

        CREATE TABLE clips (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            clip_kind TEXT NOT NULL DEFAULT 'timeline',
            name TEXT DEFAULT '',
            track_id TEXT,
            media_id TEXT,
            source_sequence_id TEXT,
            parent_clip_id TEXT,
            owner_sequence_id TEXT,
            start_time INTEGER NOT NULL,
            duration INTEGER NOT NULL,
            source_in INTEGER NOT NULL,
            source_out INTEGER NOT NULL,
            enabled BOOLEAN NOT NULL DEFAULT 1,
            offline BOOLEAN NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
            modified_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
        );

        CREATE TABLE commands (
            id TEXT PRIMARY KEY,
            parent_id TEXT,
            parent_sequence_number INTEGER,
            sequence_number INTEGER UNIQUE NOT NULL,
            command_type TEXT NOT NULL,
            command_args TEXT NOT NULL,
            pre_hash TEXT NOT NULL,
            post_hash TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            playhead_time INTEGER NOT NULL DEFAULT 0,
            selected_clip_ids TEXT,
            selected_edge_infos TEXT,
            selected_clip_ids_pre TEXT,
            selected_edge_infos_pre TEXT
        );
    ]])
end

local db_path = "/tmp/jve/test_command_manager_listeners.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
create_schema(db)

local now = os.time()
db:exec(string.format([[ 
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Listener Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, width, height,
        timecode_start, playhead_time, selected_clip_ids, selected_edge_infos,
        viewport_start_time, viewport_duration, current_sequence_number)
    VALUES ('timeline_seq', 'test_project', 'Timeline Seq', 'timeline',
        24.0, 1920, 1080, 0, 0, '[]', '[]', 0, 10000, NULL);
]], now, now))

command_manager.init(db, "timeline_seq", "test_project")

local events = {}
local listener = function(evt)
    table.insert(events, evt)
end
command_manager.add_listener(listener)

command_manager.register_executor("TestNoOpListener", function()
    return true
end, function()
    return true
end)

local cmd = Command.create("TestNoOpListener", "test_project")
local exec_result = command_manager.execute(cmd)
assert(exec_result.success, "execute should succeed")
assert(#events >= 1, "listener should capture execute event")
assert(events[#events].event == "execute", "expected execute event")
assert(events[#events].command and events[#events].command.type == "TestNoOpListener", "execute event command type mismatch")
 
local undo_result = command_manager.undo()
assert(undo_result.success, "undo should succeed")
assert(events[#events].event == "undo", "expected undo event")
assert(events[#events].command and events[#events].command.type == "TestNoOpListener", "undo event command type mismatch")

local redo_result = command_manager.redo()
assert(redo_result.success, "redo should succeed")
assert(events[#events].event == "redo", "expected redo event")
assert(events[#events].command and events[#events].command.type == "TestNoOpListener", "redo event command type mismatch")

command_manager.unregister_executor("TestNoOpListener")
command_manager.remove_listener(listener)

print("✅ Command manager listeners triggered execute/undo/redo events")
