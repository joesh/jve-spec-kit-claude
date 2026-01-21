#!/usr/bin/env luajit

-- Test undo/replay media table cleanup
-- Ensures media table is cleared before replay to prevent UNIQUE constraint violations

package.path = package.path .. ";../src/lua/?.lua;../src/lua/core/?.lua;../src/lua/models/?.lua;../tests/?.lua"

require('test_env')

local command_manager = require('core.command_manager')
local Command = require('command')
local database = require('core.database')
local Media = require('models.media')

print("=== Undo Media Cleanup Tests ===\n")

-- Setup test database
local test_db_path = "/tmp/jve/test_undo_media_cleanup.db"
os.remove(test_db_path)

database.init(test_db_path)
local db = database.get_connection()

local SCHEMA_SQL = require("import_schema")
assert(db:exec(SCHEMA_SQL))

-- Insert test data
db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Test Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('test_sequence', 'test_project', 'Test Sequence', 'timeline', 30, 1, 48000, 1920, 1080, 0, 300, 0, '[]', '[]', '[]', 0, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'test_project', 'Default Sequence', 'timeline', 30, 1, 48000, 1920, 1080, 0, 300, 0, '[]', '[]', '[]', 0, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan) VALUES ('track_v1', 'test_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan) VALUES ('track_default_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

command_manager.init('default_sequence', 'test_project')

-- Test 1: Media cleanup during replay
print("Test 1: Media cleanup during undo/replay")

-- Create ImportMedia command executor (simplified for testing)
local function execute_import_media(cmd)
    local file_path = cmd:get_parameter("file_path")
    local media_id = cmd:get_parameter("media_id") or ("media_" .. file_path:gsub("[^%w]", "_"))
    local media = Media.create({
        id = media_id,
        project_id = 'test_project',
        file_path = file_path,
        name = file_path:match('([^/]+)$'),
        duration_frames = 3000,
        fps_numerator = 30,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
        audio_channels = 2,
        codec = 'h264'
    })
    if media and media:save(db) then
        cmd:set_parameter("media_id", media_id)
        return true
    end
    return false
end

local function undo_import_media(cmd)
    local media_id = cmd:get_parameter("media_id")
    if not media_id or media_id == "" then
        return true
    end
    local stmt = db:prepare("DELETE FROM media WHERE id = ?")
    if stmt then
        stmt:bind_value(1, media_id)
        stmt:exec()
        stmt:finalize()
    end
    return true
end

-- Register test executor with a simple schema
local import_media_spec = {
    args = {
        project_id = { kind = "string", required = false },
        file_path = { kind = "string", required = true },
        media_id = { kind = "string", required = false },
    }
}
command_manager.register_executor("ImportMedia", execute_import_media, undo_import_media, import_media_spec)

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
print("Test 2: Replay gracefully handles missing sequence row")

local success, err = pcall(function()
    return command_manager.replay_events('nonexistent_sequence', 0)
end)

if not success or err == false then
    print("❌ FAIL: Replay should succeed even when sequence row is missing")
    print("   Got: " .. tostring(err) .. "\n")
    os.exit(1)
end

local verify_stmt = db:prepare("SELECT COUNT(*) FROM sequences WHERE id = 'nonexistent_sequence'")
if verify_stmt and verify_stmt:exec() and verify_stmt:next() then
    local count = verify_stmt:value(0)
    if count ~= 0 then
        print("❌ FAIL: Replay should not create missing sequence rows")
        os.exit(1)
    end
end
verify_stmt:finalize()

print("✅ PASS: Missing sequence row no longer aborts replay\n")

command_manager.unregister_executor("ImportMedia")



print("=== All Undo Media Cleanup Tests Passed ===")
os.remove(test_db_path)
os.exit(0)
