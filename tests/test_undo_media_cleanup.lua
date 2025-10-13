#!/usr/bin/env luajit

-- Test undo/replay media table cleanup
-- Ensures media table is cleared before replay to prevent UNIQUE constraint violations

package.path = package.path .. ";../src/lua/?.lua;../src/lua/core/?.lua;../src/lua/models/?.lua"

local command_manager = require('core.command_manager')
local Command = require('command')
local database = require('core.database')
local Media = require('models.media')

print("=== Undo Media Cleanup Tests ===\n")

-- Setup test database
local test_db_path = "/tmp/test_undo_media_cleanup.db"
os.remove(test_db_path)

database.init(test_db_path)
local db = database.get_connection()

-- Create schema
db:exec([[
    CREATE TABLE IF NOT EXISTS projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        current_sequence_number INTEGER
    );

    CREATE TABLE IF NOT EXISTS tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL
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
        height INTEGER,
        audio_channels INTEGER,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT
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
        selected_clip_ids TEXT DEFAULT '[]'
    );
]])

-- Insert test data
db:exec([[
    INSERT INTO projects (id, name) VALUES ('test_project', 'Test Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('test_sequence', 'test_project', 'Test Sequence', 30.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, track_type, track_index)
    VALUES ('track_v1', 'test_sequence', 'VIDEO', 1);
]])

command_manager.init(db, 'test_sequence')

-- Test 1: Media cleanup during replay
print("Test 1: Media cleanup during undo/replay")

-- Create ImportMedia command executor (simplified for testing)
local function execute_import_media(cmd)
    local file_path = cmd:get_parameter("file_path")
    local media = Media.create(
        "test_project",
        file_path,
        file_path:match("([^/]+)$"),  -- name from path
        10000,  -- duration
        30.0,   -- frame_rate
        1920, 1080,
        2,      -- audio_channels
        "h264"
    )
    if media and media:save(db) then
        cmd:set_parameter("media_id", media.id)
        return true
    end
    return false
end

-- Register temporary ImportMedia executor
package.loaded['core.command_manager'].register_executor("ImportMedia", execute_import_media)

-- Import first media file
local import1 = Command.create("ImportMedia", "test_project")
import1:set_parameter("file_path", "/test/video1.mp4")
local result1 = command_manager.execute(import1)

if not result1.success then
    print("❌ FAIL: First import failed")
    os.exit(1)
end

-- Import second media file
local import2 = Command.create("ImportMedia", "test_project")
import2:set_parameter("file_path", "/test/video2.mp4")
local result2 = command_manager.execute(import2)

if not result2.success then
    print("❌ FAIL: Second import failed")
    os.exit(1)
end

-- Verify 2 media items exist
local count_query = db:prepare("SELECT COUNT(*) FROM media WHERE project_id = 'test_project'")
if not (count_query and count_query:exec() and count_query:next()) then
    print("❌ FAIL: Cannot query media count")
    os.exit(1)
end
local media_count = count_query:value(0)

if media_count ~= 2 then
    print("❌ FAIL: Expected 2 media items, found " .. media_count)
    os.exit(1)
end
print("✓ Imported 2 media files successfully")

-- Undo second import (should trigger replay which clears and recreates media)
command_manager.undo()

-- Verify only 1 media item remains
count_query = db:prepare("SELECT COUNT(*) FROM media WHERE project_id = 'test_project'")
if not (count_query and count_query:exec() and count_query:next()) then
    print("❌ FAIL: Cannot query media count after undo")
    os.exit(1)
end
media_count = count_query:value(0)

if media_count ~= 1 then
    print("❌ FAIL: Expected 1 media item after undo, found " .. media_count)
    os.exit(1)
end
print("✓ After undo: 1 media file remains")

-- Redo should recreate second media without constraint violation
command_manager.redo()

count_query = db:prepare("SELECT COUNT(*) FROM media WHERE project_id = 'test_project'")
if not (count_query and count_query:exec() and count_query:next()) then
    print("❌ FAIL: Cannot query media count after redo")
    os.exit(1)
end
media_count = count_query:value(0)

if media_count ~= 2 then
    print("❌ FAIL: Expected 2 media items after redo, found " .. media_count)
    os.exit(1)
end
print("✓ After redo: 2 media files restored")

print("✅ PASS: Media cleanup prevents UNIQUE constraint violations\n")

-- Test 2: project_id query failure detection
print("Test 2: Project ID query failure is detected")

-- Try to replay with invalid sequence_id
local success, err = pcall(function()
    command_manager.replay_events('nonexistent_sequence', 0)
end)

if not success and err:match("Cannot determine project_id") then
    print("✅ PASS: Missing project_id correctly throws error\n")
else
    print("❌ FAIL: Should have thrown error for missing project_id")
    print("   Got: " .. tostring(err) .. "\n")
    os.exit(1)
end

print("=== All Undo Media Cleanup Tests Passed ===")
os.remove(test_db_path)
os.exit(0)
