#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

local function stub_timeline_state()
    timeline_state.capture_viewport = function()
        return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 24}
    end
    timeline_state.push_viewport_guard = function() end
    timeline_state.pop_viewport_guard = function() end
    timeline_state.restore_viewport = function(_) end
    timeline_state.set_selection = function(_) end
    timeline_state.get_selected_clips = function() return {} end
    timeline_state.set_edge_selection = function(_) end
    timeline_state.get_selected_edges = function() return {} end
    timeline_state.set_playhead_time = function(_) end
    timeline_state.get_playhead_time = function() return 0 end
    timeline_state.reload_clips = function() end
end

local function query_property(db, clip_id, property_name)
    local stmt = db:prepare([[
        SELECT property_value, property_type, default_value
        FROM properties
        WHERE clip_id = ? AND property_name = ?
    ]])
    if not stmt then
        error("Failed to prepare property query")
    end
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, property_name)

    local row = nil
    if stmt:exec() and stmt:next() then
        row = {
            property_value = stmt:value(0),
            property_type = stmt:value(1),
            default_value = stmt:value(2)
        }
    end
    stmt:finalize()
    return row
end

local function JSON_decode(raw)
    local ok, value = pcall(qt_json_decode, raw)
    if not ok then
        error("Failed to decode JSON: " .. tostring(value))
    end
    return value
end

print("=== SetClipProperty Command Tests ===")

local db_path = "/tmp/jve/test_set_clip_property.db"
os.remove(db_path)

assert(database.init(db_path))
local db = database.get_connection()

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
        audio_sample_rate INTEGER NOT NULL DEFAULT 48000,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start_frame INTEGER NOT NULL DEFAULT 0,
        playhead_frame INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_frame INTEGER NOT NULL DEFAULT 0,
        viewport_duration_frames INTEGER NOT NULL DEFAULT 240,
        mark_in_frame INTEGER,
        mark_out_frame INTEGER,
        current_sequence_number INTEGER
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
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
        name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        duration_value INTEGER NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER DEFAULT 0,
        height INTEGER DEFAULT 0,
        audio_channels INTEGER DEFAULT 0,
        codec TEXT DEFAULT '',
        created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL,
        metadata TEXT NOT NULL DEFAULT '{}'
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
        start_value INTEGER NOT NULL,
        duration_value INTEGER NOT NULL,
        source_in_value INTEGER NOT NULL,
        source_out_value INTEGER NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
        enabled BOOLEAN NOT NULL DEFAULT 1,
        offline BOOLEAN NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        modified_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    );

    CREATE TABLE properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT NOT NULL,
        property_type TEXT NOT NULL CHECK(property_type IN ('STRING','NUMBER','BOOLEAN','COLOR','ENUM')),
        default_value TEXT NOT NULL,
        FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE,
        UNIQUE(clip_id, property_name)
    );

    CREATE INDEX IF NOT EXISTS idx_properties_clip ON properties(clip_id);

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
        playhead_value INTEGER NOT NULL DEFAULT 0,
        playhead_rate REAL NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        selected_clip_ids_pre TEXT,
        selected_edge_infos_pre TEXT
    );
]])

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Property Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
        timecode_start_frame, playhead_frame, selected_clip_ids, selected_edge_infos,
        viewport_start_frame, viewport_duration_frames, current_sequence_number)
    VALUES ('timeline_seq', 'test_project', 'Timeline Seq', 'timeline',
        24.0, 48000, 1920, 1080, 0, 0, '[]', '[]', 0, 240, NULL);
]], now, now))

stub_timeline_state()
command_manager.init(db, "timeline_seq", "test_project")

local media_reader = require("media.media_reader")
local original_import = media_reader.import_media

media_reader.import_media = function(_, _, _, existing_media_id)
    local media_id = existing_media_id or "media_001"
    local metadata = {
        duration_ms = 4000,
        has_video = true,
        video = {width = 1920, height = 1080, frame_rate = 24.0, codec = "prores"},
        has_audio = true,
        audio = {channels = 2, sample_rate = 48000, codec = "aac"},
    }
    return media_id, metadata
end

local import_cmd = Command.create("ImportMedia", "test_project")
import_cmd:set_parameter("file_path", "/tmp/jve/test_source.mov")
import_cmd:set_parameter("project_id", "test_project")

local import_result = command_manager.execute(import_cmd)
assert(import_result.success, "ImportMedia command failed: " .. tostring(import_result.error_message))

local master_clip_id = import_cmd:get_parameter("master_clip_id")
assert(master_clip_id and master_clip_id ~= "", "Expected master_clip_id from ImportMedia")

local property_name = "audio:sample_rate"

print("Test 1: Setting new clip property creates property row")
local set_cmd = Command.create("SetClipProperty", "test_project")
set_cmd:set_parameter("clip_id", master_clip_id)
set_cmd:set_parameter("property_name", property_name)
set_cmd:set_parameter("value", "48000")
set_cmd:set_parameter("property_type", "STRING")
set_cmd:set_parameter("default_value", "44100")

local set_result = command_manager.execute(set_cmd)
assert(set_result.success, "SetClipProperty command failed: " .. tostring(set_result.error_message))

local property_row = query_property(db, master_clip_id, property_name)
assert(property_row, "Property row not created")

local decoded_value = JSON_decode(property_row.property_value)
assert(decoded_value.value == "48000", "Expected property value 48000, got " .. tostring(decoded_value.value))
assert(property_row.property_type == "STRING", "Expected property type STRING, got " .. tostring(property_row.property_type))

print("Test 2: Undo removes newly created property")
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo failed: " .. tostring(undo_result.error_message))
local row_after_undo = query_property(db, master_clip_id, property_name)
assert(row_after_undo == nil, "Property row should be removed after undo")

print("Test 3: Redo recreates property with original value")
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo failed: " .. tostring(redo_result.error_message))
local row_after_redo = query_property(db, master_clip_id, property_name)
assert(row_after_redo, "Property row missing after redo")
local decoded_after_redo = JSON_decode(row_after_redo.property_value)
assert(decoded_after_redo.value == "48000", "Redo restored incorrect property value: " .. tostring(decoded_after_redo.value))

print("✅ All SetClipProperty tests passed")

media_reader.import_media = original_import
