#!/usr/bin/env luajit

-- Regression test for ImportMedia command: ensures master clip hierarchy is created,
-- undo removes it cleanly, and redo restores it.

package.path = package.path .. ";../src/lua/?.lua;../src/lua/core/?.lua;../src/lua/models/?.lua;../src/lua/ui/?.lua;../tests/?.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local media_reader = require("media.media_reader")
local Media = require("models.media")

local function create_schema(db)
    db:exec([[
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
            settings TEXT DEFAULT '{}'
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

        CREATE TABLE IF NOT EXISTS media (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            file_path TEXT NOT NULL,
            duration INTEGER NOT NULL,
            frame_rate REAL NOT NULL,
            width INTEGER DEFAULT 0,
            height INTEGER DEFAULT 0,
            audio_channels INTEGER DEFAULT 0,
            codec TEXT DEFAULT '',
            created_at INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
            metadata TEXT DEFAULT '{}'
        );

        CREATE TABLE IF NOT EXISTS clips (
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

        CREATE TABLE IF NOT EXISTS properties (
            id TEXT PRIMARY KEY,
            clip_id TEXT NOT NULL,
            property_name TEXT NOT NULL,
            property_value TEXT NOT NULL,
            property_type TEXT NOT NULL CHECK(property_type IN ('STRING', 'NUMBER', 'BOOLEAN', 'COLOR', 'ENUM')),
            default_value TEXT NOT NULL,
            FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE,
            UNIQUE(clip_id, property_name)
        );

        CREATE INDEX IF NOT EXISTS idx_properties_clip ON properties(clip_id);

        CREATE TABLE IF NOT EXISTS commands (
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

local function count_rows(db, table_name, where_clause, value)
    local sql = string.format("SELECT COUNT(*) FROM %s", table_name)
    if where_clause then
        sql = sql .. " WHERE " .. where_clause
    end
    local stmt = db:prepare(sql)
    if where_clause and value ~= nil and stmt then
        stmt:bind_value(1, value)
    end
    local count = 0
    if stmt and stmt:exec() and stmt:next() then
        count = stmt:value(0) or 0
    end
    if stmt then
        stmt:finalize()
    end
    return count
end

print("=== ImportMedia Command Tests ===\n")

local test_db_path = "/tmp/jve/test_import_media_command.db"
os.remove(test_db_path)

assert(database.init(test_db_path))
local db = database.get_connection()
create_schema(db)

-- Seed default project/sequence
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('test_project', 'Test Project', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, frame_rate, width, height, timecode_start, playhead_time, selected_clip_ids, selected_edge_infos, viewport_start_time, viewport_duration, current_sequence_number)
    VALUES ('default_sequence', 'test_project', 'Default Timeline', 'timeline', 30.0, 1920, 1080, 0, 0, '[]', '[]', 0, 10000, NULL);
]], now, now))

command_manager.init(db, "default_sequence", "test_project")

-- Stub MediaReader.import_media to avoid ffprobe dependency
local original_import = media_reader.import_media
media_reader.import_media = function(file_path, db_conn, project_id, existing_media_id)
    local media_id = existing_media_id or "media_stub"
    local metadata = {
        duration_ms = 4000,
        has_video = true,
        video = {
            width = 1280,
            height = 720,
            frame_rate = 24.0,
            codec = "h264",
        },
        has_audio = true,
        audio = {
            channels = 2,
            sample_rate = 48000,
            codec = "aac",
        },
    }

    local media_record = Media.create({
        id = media_id,
        project_id = project_id,
        name = file_path:match("([^/\\]+)$") or file_path,
        file_path = file_path,
        duration = metadata.duration_ms,
        frame_rate = metadata.video and metadata.video.frame_rate or 0,
        width = metadata.video and metadata.video.width or 0,
        height = metadata.video and metadata.video.height or 0,
        audio_channels = metadata.audio and metadata.audio.channels or 0,
        codec = metadata.video and metadata.video.codec or metadata.audio.codec or "",
        metadata = '{}',
        created_at = os.time(),
        modified_at = os.time()
    })
    assert(media_record, "Failed to create stub media record")
    assert(media_record:save(db_conn), "Failed to persist stub media record")

    return media_id, metadata
end

local function assert_master_state(expected_count)
    local master_clips = database.load_master_clips("test_project")
    assert(#master_clips == expected_count, string.format("Expected %d master clip(s); found %d", expected_count, #master_clips))
    return master_clips
end

-- Execute ImportMedia
local import_cmd = Command.create("ImportMedia", "test_project")
import_cmd:set_parameter("file_path", "/tmp/jve/test_source.mov")

local result = command_manager.execute(import_cmd)
assert(result.success, "ImportMedia command failed to execute")

local master_clips = assert_master_state(1)
local master_clip = master_clips[1]
assert(master_clip.media_id == "media_stub", "Master clip should reference stub media id")
assert(master_clip.sequence and master_clip.sequence.id, "Master clip should point to a source sequence")

local master_sequence_id = master_clip.source_sequence_id
assert(master_sequence_id ~= nil, "Master clip should store source_sequence_id")

-- Verify sequence and tracks created
assert(count_rows(db, "sequences", "id = ?", master_sequence_id) == 1, "Master sequence missing")
assert(count_rows(db, "tracks", "sequence_id = ?", master_sequence_id) >= 1, "Master sequence should have tracks")
assert(count_rows(db, "clips", "parent_clip_id = ?", master_clip.clip_id) >= 1, "Master clip should have child clips")
assert(count_rows(db, "media", "id = ?", master_clip.media_id) == 1, "Media row missing after import")

-- Undo
command_manager.undo()
assert_master_state(0)
assert(count_rows(db, "sequences", "id = ?", master_sequence_id) == 0, "Master sequence should be removed after undo")
assert(count_rows(db, "tracks", "sequence_id = ?", master_sequence_id) == 0, "Master tracks should be removed after undo")
assert(count_rows(db, "clips", "parent_clip_id = ?", master_clip.clip_id) == 0, "Child clips should be removed after undo")
assert(count_rows(db, "media", "id = ?", master_clip.media_id) == 0, "Media row should be removed after undo")

-- Redo
command_manager.redo()
master_clips = assert_master_state(1)
local redo_clip = master_clips[1]
assert(redo_clip.source_sequence_id ~= nil, "Redo should recreate master sequence")
assert(count_rows(db, "tracks", "sequence_id = ?", redo_clip.source_sequence_id) >= 1, "Redo should recreate tracks")
assert(count_rows(db, "media", "id = ?", redo_clip.media_id) == 1, "Redo should recreate media row")

media_reader.import_media = original_import

print("✅ PASS: ImportMedia command creates and restores master clip hierarchy with undo/redo\n")
