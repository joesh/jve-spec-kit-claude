#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local command_impl = require("core.command_implementations")
local timeline_state = require("ui.timeline.timeline_state")
local Command = require("command")

local TEST_DB = "/tmp/jve/test_delete_sequence.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()

local schema_sql = [[
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
        offline INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT NOT NULL,
        property_type TEXT NOT NULL,
        default_value TEXT NOT NULL
    );

    CREATE TABLE clip_links (
        link_group_id TEXT NOT NULL,
        clip_id TEXT NOT NULL,
        role TEXT NOT NULL,
        time_offset INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (link_group_id, clip_id)
    );

    CREATE TABLE snapshots (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        sequence_number INTEGER NOT NULL,
        clips_state TEXT NOT NULL,
        created_at INTEGER NOT NULL
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

assert(db:exec(schema_sql))

local now = os.time()

local seed_sql = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, width, height, current_sequence_number)
    VALUES ('default_sequence', 'default_project', 'Primary Timeline', 'timeline', 30.0, 1920, 1080, 0);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, width, height, current_sequence_number)
    VALUES ('sequence_to_delete', 'default_project', 'Temp Timeline', 'timeline', 24.0, 1280, 720, 5);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_video_1', 'sequence_to_delete', 'Video 1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES ('media_1', 'default_project', 'Clip Media', '/tmp/jve/clip.mov', 24000, 24.0, 1280, 720, 2, 'h264', %d, %d, '{}');

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       start_time, duration, source_in, source_out, enabled, offline, created_at, modified_at)
    VALUES ('clip_1', 'default_project', 'timeline', 'Temp Clip', 'track_video_1', 'media_1', 'sequence_to_delete',
            0, 24000, 0, 24000, 1, 0, %d, %d);

    INSERT INTO properties (id, clip_id, property_name, property_value, property_type, default_value)
    VALUES ('prop_1', 'clip_1', 'opacity', '{"value":0.5}', 'NUMBER', '{"value":1.0}');

    INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
    VALUES ('group_1', 'clip_1', 'VIDEO', 0, 1);

    INSERT INTO snapshots (id, sequence_id, sequence_number, clips_state, created_at)
    VALUES ('snapshot_1', 'sequence_to_delete', 5, '[]', %d);
]], now, now, now, now, now, now, now)

assert(db:exec(seed_sql))

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
    timeline_state.get_project_id = function() return "default_project" end
    timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.reload_clips = function(_) end
end

stub_timeline_state()

command_manager.init(db, "default_sequence", "default_project")
do
    local delete_module = require("core.commands.delete_sequence")
    local temp_executors = {}
    local temp_undoers = {}
    local exports = delete_module.register(temp_executors, temp_undoers, db, command_manager.set_last_error)
    if not exports or type(exports.executor) ~= "function" then
        error("DeleteSequence executor not available from delete_sequence module")
    end
    command_manager.register_executor("DeleteSequence", exports.executor, exports.undoer)
end

local function scalar(sql, value)
    local stmt = db:prepare(sql)
    assert(stmt, "Failed to prepare statement: " .. sql)
    if value ~= nil then
        stmt:bind_value(1, value)
    end
    local result = 0
    if stmt:exec() and stmt:next() then
        result = tonumber(stmt:value(0)) or 0
    end
    stmt:finalize()
    return result
end

local function fetch_property_value()
    local stmt = db:prepare("SELECT property_value FROM properties WHERE id = 'prop_1'")
    assert(stmt and stmt:exec(), "Failed to query property")
    local value = nil
    if stmt:next() then
        value = stmt:value(0)
    end
    stmt:finalize()
    return value
end

local delete_cmd = Command.create("DeleteSequence", "default_project")
delete_cmd:set_parameter("sequence_id", "sequence_to_delete")

local exec_result = command_manager.execute(delete_cmd)
assert(exec_result.success, exec_result.error_message or "delete sequence failed")

assert(scalar("SELECT COUNT(*) FROM sequences WHERE id = ?", "sequence_to_delete") == 0, "Sequence should be deleted")
assert(scalar("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?", "sequence_to_delete") == 0, "Tracks should cascade delete")
assert(scalar("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = ?", "sequence_to_delete") == 0, "Clips should cascade delete")
assert(scalar("SELECT COUNT(*) FROM properties WHERE clip_id = 'clip_1'") == 0, "Clip properties should be removed")
assert(scalar("SELECT COUNT(*) FROM clip_links WHERE clip_id = 'clip_1'") == 0, "Clip links should be removed")
assert(scalar("SELECT COUNT(*) FROM snapshots WHERE sequence_id = ?", "sequence_to_delete") == 0, "Snapshots should be removed")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")

assert(scalar("SELECT COUNT(*) FROM sequences WHERE id = ?", "sequence_to_delete") == 1, "Sequence should be restored on undo")
assert(scalar("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?", "sequence_to_delete") == 1, "Track should be restored on undo")
assert(scalar("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = ?", "sequence_to_delete") == 1, "Clip should be restored on undo")
assert(fetch_property_value() == '{"value":0.5}', "Property value should be restored")
assert(scalar("SELECT COUNT(*) FROM clip_links WHERE clip_id = 'clip_1'") == 1, "Clip links should be restored")
assert(scalar("SELECT COUNT(*) FROM snapshots WHERE sequence_id = ?", "sequence_to_delete") == 1, "Snapshot should be restored")

local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo failed")

assert(scalar("SELECT COUNT(*) FROM sequences WHERE id = ?", "sequence_to_delete") == 0, "Sequence should be deleted after redo")
assert(scalar("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?", "sequence_to_delete") == 0, "Tracks should be removed after redo")
assert(scalar("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = ?", "sequence_to_delete") == 0, "Clips should be removed after redo")
assert(scalar("SELECT COUNT(*) FROM clip_links WHERE clip_id = 'clip_1'") == 0, "Clip links should be removed after redo")

os.remove(TEST_DB)
print("✅ DeleteSequence command deletes and restores timeline state correctly")
