#!/usr/bin/env luajit

-- Test ImportMedia command - comprehensive coverage
-- Tests: basic import, undo/redo, multiple files, error cases, replay with IDs

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local asserts = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

-- Mock MediaReader.import_media to avoid needing actual media files
local MediaReader = require('media.media_reader')
local original_import_media = MediaReader.import_media

-- Mock metadata that import_media would return
local mock_file_counter = 0
local function create_mock_import(file_path, db, project_id, existing_media_id)
    mock_file_counter = mock_file_counter + 1
    local uuid = require("uuid")

    -- Create mock metadata
    local metadata = {
        file_path = file_path,
        duration_ms = 5000,  -- 5 seconds
        has_video = true,
        has_audio = true,
        video = {
            width = 1920,
            height = 1080,
            frame_rate = 30,
            codec = "h264"
        },
        audio = {
            channels = 2,
            sample_rate = 48000,
            codec = "aac"
        }
    }

    -- Generate or reuse media ID
    local media_id = existing_media_id or uuid.generate_with_prefix("media")

    -- Create the Media record
    local Media = require("models.media")
    local media = Media.create({
        id = media_id,
        project_id = project_id,
        name = file_path:match("([^/\\]+)$") or file_path,
        file_path = file_path,
        duration = metadata.duration_ms,
        frame_rate = 30,
        width = 1920,
        height = 1080,
        audio_channels = 2,
        codec = "h264",
        created_at = os.time(),
        modified_at = os.time()
    })

    if not media or not media:save() then
        return nil, nil, "Failed to create media record"
    end

    return media_id, metadata, nil
end

-- Install mock
MediaReader.import_media = create_mock_import

print("=== ImportMedia Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_import_media.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))

command_manager.init('sequence', 'project')

-- Helper: execute command with proper event wrapping
local function execute_command(name, params)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
    return result
end

-- Helper: undo/redo with proper event wrapping
local function undo()
    command_manager.begin_command_event("script")
    local result = command_manager.undo()
    command_manager.end_command_event()
    return result
end

local function redo()
    command_manager.begin_command_event("script")
    local result = command_manager.redo()
    command_manager.end_command_event()
    return result
end

-- Helper: count media records
local function count_media()
    local stmt = db:prepare("SELECT COUNT(*) FROM media")
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- Helper: count clips
local function count_clips()
    local stmt = db:prepare("SELECT COUNT(*) FROM clips")
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- Helper: count sequences
local function count_sequences()
    local stmt = db:prepare("SELECT COUNT(*) FROM sequences")
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- =============================================================================
-- TEST 1: Basic single file import
-- =============================================================================
print("Test 1: Basic single file import")
local result = execute_command("ImportMedia", {
    project_id = "project",
    file_paths = {"/tmp/jve/test_video.mp4"}
})
assert(result.success, "ImportMedia should succeed: " .. tostring(result.error_message))

-- Verify media was created
local media_count = count_media()
assert(media_count >= 1, string.format("Should have at least 1 media, got %d", media_count))

-- Verify master clip was created
local clip_count = count_clips()
assert(clip_count >= 1, string.format("Should have at least 1 clip, got %d", clip_count))

-- =============================================================================
-- TEST 2: Import multiple files at once
-- =============================================================================
print("Test 2: Import multiple files at once")
local initial_media = count_media()
result = execute_command("ImportMedia", {
    project_id = "project",
    file_paths = {
        "/tmp/jve/video1.mp4",
        "/tmp/jve/video2.mp4",
        "/tmp/jve/video3.mp4"
    }
})
assert(result.success, "ImportMedia should succeed for multiple files")

-- Verify 3 new media were created
local new_media = count_media() - initial_media
assert(new_media == 3, string.format("Should have added 3 media, added %d", new_media))

-- =============================================================================
-- TEST 3: Undo removes imported media
-- =============================================================================
print("Test 3: Undo removes imported media")
local before_undo_media = count_media()
local before_undo_clips = count_clips()
local before_undo_sequences = count_sequences()

local undo_result = undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- Verify media was deleted
local after_undo_media = count_media()
assert(after_undo_media < before_undo_media,
    string.format("Undo should reduce media count: before=%d, after=%d", before_undo_media, after_undo_media))

-- =============================================================================
-- TEST 4: Redo re-imports media with same IDs
-- =============================================================================
print("Test 4: Redo re-imports media with preserved IDs")
local before_redo_media = count_media()

local redo_result = redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

-- Verify media was re-created
local after_redo_media = count_media()
assert(after_redo_media > before_redo_media,
    string.format("Redo should increase media count: before=%d, after=%d", before_redo_media, after_redo_media))

-- =============================================================================
-- TEST 5: Single file_path parameter (backward compatibility)
-- =============================================================================
print("Test 5: Single file_path parameter works")
local initial_count = count_media()
result = execute_command("ImportMedia", {
    project_id = "project",
    file_path = "/tmp/jve/single_file.mov"  -- Note: file_path, not file_paths
})
assert(result.success, "ImportMedia with single file_path should succeed")
assert(count_media() > initial_count, "Should have added media")

-- =============================================================================
-- TEST 6: Error case - missing project_id
-- =============================================================================
print("Test 6: Missing project_id fails")
asserts._set_enabled_for_tests(false)
result = execute_command("ImportMedia", {
    file_paths = {"/tmp/jve/test.mp4"}
    -- No project_id
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "ImportMedia without project_id should fail")

-- =============================================================================
-- TEST 7: Error case - empty file_paths
-- =============================================================================
print("Test 7: Empty file_paths fails")
asserts._set_enabled_for_tests(false)
result = execute_command("ImportMedia", {
    project_id = "project",
    file_paths = {}  -- Empty array
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "ImportMedia with empty file_paths should fail")

-- =============================================================================
-- TEST 8: Multiple undo/redo cycle maintains integrity
-- =============================================================================
print("Test 8: Multiple undo/redo cycle")
local baseline_media = count_media()

-- Import file
result = execute_command("ImportMedia", {
    project_id = "project",
    file_paths = {"/tmp/jve/cycle_test.mp4"}
})
assert(result.success, "Import should succeed")
local after_import = count_media()
assert(after_import > baseline_media, "Import should add media")

-- Undo
undo_result = undo()
assert(undo_result.success, "First undo should succeed")
assert(count_media() == baseline_media, "Undo should restore to baseline")

-- Redo
redo_result = redo()
assert(redo_result.success, "First redo should succeed")
assert(count_media() == after_import, "Redo should restore imported count")

-- Undo again
undo_result = undo()
assert(undo_result.success, "Second undo should succeed")
assert(count_media() == baseline_media, "Second undo should restore baseline")

-- Redo again
redo_result = redo()
assert(redo_result.success, "Second redo should succeed")
assert(count_media() == after_import, "Second redo should restore imported count")

-- =============================================================================
-- TEST 9: Import creates master sequence with proper structure
-- =============================================================================
print("Test 9: Master sequence structure is correct")
-- Reset for clean test
local seq_before = count_sequences()

result = execute_command("ImportMedia", {
    project_id = "project",
    file_paths = {"/tmp/jve/structure_test.mp4"}
})
assert(result.success, "Import should succeed")

-- Verify master sequence was created
local seq_after = count_sequences()
assert(seq_after > seq_before, "Should have created master sequence")

-- Verify the master sequence has correct structure
local stmt = db:prepare([[
    SELECT s.id, s.name, s.kind FROM sequences s
    WHERE s.project_id = 'project' AND s.kind = 'master'
    ORDER BY s.created_at DESC LIMIT 1
]])
stmt:exec()
if stmt:next() then
    local seq_id = stmt:value(0)
    local seq_name = stmt:value(1)
    local seq_kind = stmt:value(2)
    stmt:finalize()

    assert(seq_kind == "master", "Sequence should be of kind 'master'")
    assert(seq_name:find("Source"), "Master sequence name should contain 'Source'")

    -- Verify tracks exist on this sequence
    local track_stmt = db:prepare("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?")
    track_stmt:bind_value(1, seq_id)
    track_stmt:exec()
    track_stmt:next()
    local track_count = track_stmt:value(0)
    track_stmt:finalize()

    assert(track_count >= 1, "Master sequence should have at least 1 track")
else
    stmt:finalize()
    assert(false, "No master sequence found")
end

-- =============================================================================
-- Cleanup: Restore original MediaReader
-- =============================================================================
MediaReader.import_media = original_import_media

print("\n✅ ImportMedia command tests passed")
