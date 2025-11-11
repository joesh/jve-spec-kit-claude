#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
local Command = require('command')

local TEST_DB = "/tmp/test_duplicate_master_clip.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0,
        settings TEXT NOT NULL DEFAULT '{}'
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

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT,
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
        clip_kind TEXT NOT NULL,
        name TEXT,
        track_id TEXT,
        media_id TEXT,
        source_sequence_id TEXT,
        parent_clip_id TEXT,
        owner_sequence_id TEXT,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL,
        source_out INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        offline INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT,
        property_type TEXT NOT NULL DEFAULT 'STRING',
        default_value TEXT
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

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 24.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('video1', 'default_sequence', 'V1', 'VIDEO', 1, 1);
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate)
    VALUES ('media_master', 'default_project', 'Master Source', '/tmp/master.mov', 2000, 24.0);
    INSERT INTO clips (id, project_id, clip_kind, name, media_id, start_time, duration, source_in, source_out, enabled, offline)
    VALUES ('master_clip', 'default_project', 'master', 'Master Clip', 'media_master', 0, 2000, 0, 2000, 1, 0);
    INSERT INTO properties (id, clip_id, property_name, property_value, property_type, default_value)
    VALUES ('prop1', 'master_clip', 'ColorBalance', '{"value":"warm"}', 'STRING', '{}');

    INSERT INTO tags (id, project_id, namespace_id, name, path, sort_index)
    VALUES ('bin_target', 'default_project', 'bin', 'Target Bin', 'Target Bin', 1);
]])

local timeline_state_stub = {
    get_selected_clips = function() return {} end,
    get_clip_by_id = function() return nil end,
    get_sequence_id = function() return "default_sequence" end,
    get_project_id = function() return "default_project" end,
    get_selected_edges = function() return {} end,
    set_selection = function() end,
    reload_clips = function() end,
    persist_state_to_db = function() end,
    get_playhead_time = function() return 0 end,
    set_playhead_time = function() end,
    get_clips = function() return {} end,
    capture_viewport = function() return {start_time = 0, duration = 10000} end,
    restore_viewport = function() end,
    push_viewport_guard = function() return 0 end,
    pop_viewport_guard = function() return 0 end
}

package.loaded["ui.timeline.timeline_state"] = timeline_state_stub
package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "project_browser" end,
    set_focused_panel = function() end
}

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)
assert(type(undoers["DuplicateMasterClip"]) == "function", "DuplicateMasterClip undoer not registered")
command_manager.init(db, 'default_sequence', 'default_project')

local snapshot = {
    name = "Master Clip",
    media_id = "media_master",
    duration = 2000,
    source_in = 0,
    source_out = 2000,
    source_sequence_id = nil,
    start_time = 0,
    enabled = true,
    offline = false,
    project_id = "default_project"
}

local cmd = Command.create("DuplicateMasterClip", "default_project")
cmd:set_parameter("clip_snapshot", snapshot)
cmd:set_parameter("bin_id", "bin_target")
cmd:set_parameter("new_clip_id", "master_clip_copy")
cmd:set_parameter("name", "Master Clip Copy")
cmd:set_parameter("copied_properties", {
    {property_name = "ColorBalance", property_value = '{"value":"warm"}', property_type = "STRING", default_value = '{}'}
})

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "DuplicateMasterClip failed")

local verify_stmt = db:prepare([[SELECT clip_kind, media_id FROM clips WHERE id = 'master_clip_copy']])
assert(verify_stmt:exec() and verify_stmt:next())
local clip_kind = verify_stmt:value(0)
local media_id = verify_stmt:value(1)
verify_stmt:finalize()
assert(clip_kind == "master", "duplicated clip should be a master clip")
assert(media_id == "media_master", "duplicated clip should reference original media")

local bin_map = database.load_master_clip_bin_map("default_project")
assert(bin_map["master_clip_copy"] == "bin_target", "duplicated clip should be assigned to target bin")

local undo_result = command_manager.undo()
assert(undo_result.success, "Undo DuplicateMasterClip should succeed")

local check_stmt = db:prepare([[SELECT COUNT(*) FROM clips WHERE id = 'master_clip_copy']])
assert(check_stmt:exec() and check_stmt:next())
assert(check_stmt:value(0) == 0, "duplicated clip should be removed after undo")
check_stmt:finalize()

local bin_map_after = database.load_master_clip_bin_map("default_project")
assert(bin_map_after["master_clip_copy"] == nil, "bin map entry should be cleared after undo")

print("✅ DuplicateMasterClip command creates master clips with bin assignment and undoes cleanly")
