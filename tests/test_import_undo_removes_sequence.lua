#!/usr/bin/env luajit

-- Regression: importing a sequence and undoing back to the root should remove
-- the imported timeline and its media instead of leaving an empty shell behind.

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Command = require("command")

local function stub_timeline_state()
    local current_sequence_id = "default_sequence"

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
    timeline_state.get_project_id = function() return "default_project" end
    timeline_state.get_sequence_id = function() return current_sequence_id end
    timeline_state.reload_clips = function(sequence_id)
        if sequence_id and sequence_id ~= "" then
            current_sequence_id = sequence_id
        end
    end
end

local function exec(db, sql)
    local ok, err = db:exec(sql)
    assert(ok, err)
end

local function scalar(db, sql, value)
    local stmt = db:prepare(sql)
    assert(stmt, "Failed to prepare statement: " .. sql)
    if value ~= nil then
        stmt:bind_value(1, value)
    end
    local result = 0
    if stmt:exec() and stmt:next() then
        result = stmt:value(0) or 0
    end
    stmt:finalize()
    return result
end

local tmp_db = "/tmp/jve/test_import_undo_removes_sequence.db"
os.remove(tmp_db)
assert(database.init(tmp_db))
local db = database.get_connection()

exec(db, [[
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
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
    );

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT,
        file_path TEXT,
        duration INTEGER,
        frame_rate REAL,
        width INTEGER,
        height INTEGER,
        audio_channels INTEGER,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT
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
        source_in INTEGER NOT NULL DEFAULT 0,
        source_out INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        offline INTEGER NOT NULL DEFAULT 0
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
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]'
    );

    CREATE TABLE tag_namespaces (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL
    );

    INSERT OR IGNORE INTO tag_namespaces(id, display_name)
    VALUES('bin', 'Bins');

    CREATE TABLE tags (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        parent_id TEXT,
        sort_index INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    );

    CREATE TABLE tag_assignments (
        tag_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        assigned_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(tag_id, entity_type, entity_id)
    );
]])

local now = os.time()
exec(db, string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence 1', 'timeline', 30.0, 1920, 1080);
]], now, now))

stub_timeline_state()

command_manager.init(db, "default_sequence", "default_project")
command_manager.activate_timeline_stack("default_sequence")

local fixture_path = "../tests/fixtures/resolve/sample_timeline_fcp7xml.xml"

local import_cmd = Command.create("ImportFCP7XML", "default_project")
import_cmd:set_parameter("project_id", "default_project")
import_cmd:set_parameter("xml_path", fixture_path)

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success, "ImportFCP7XML command should succeed")

local baseline_sequences = scalar(db, "SELECT COUNT(*) FROM sequences WHERE kind = 'timeline'")
assert(baseline_sequences == 2, "Import should create an additional timeline sequence")

local imported_exists = scalar(db, "SELECT COUNT(*) FROM sequences WHERE name = 'Timeline 1 (Resolve)'")
assert(imported_exists == 1, "Imported sequence should be present after import")

local undo_result = command_manager.undo()
assert(undo_result.success, "Undoing the import should succeed")

local sequences_after = scalar(db, "SELECT COUNT(*) FROM sequences WHERE kind = 'timeline'")
assert(sequences_after == 1, "Undo should remove the imported timeline sequence")

local imported_after = scalar(db, "SELECT COUNT(*) FROM sequences WHERE name = 'Timeline 1 (Resolve)'")
assert(imported_after == 0, "Imported sequence should be gone after undo")

local media_after = scalar(db, "SELECT COUNT(*) FROM media")
assert(media_after == 0, "Imported media should be removed after undo")

os.remove(tmp_db)
print("✅ Import undo removes generated timeline and media")
