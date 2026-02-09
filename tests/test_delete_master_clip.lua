#!/usr/bin/env luajit

-- Test DeleteMasterClip command - comprehensive coverage
-- Tests: basic delete, undo/redo, in-use prevention, child clip cleanup

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Sequence = require('models.sequence')
local Track = require('models.track')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')
local asserts = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== DeleteMasterClip Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_delete_master_clip.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project/Sequence (30fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Main Sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- Create Media
local media = Media.create({
    id = "media_dmc",
    project_id = "project",
    file_path = "/tmp/jve/dmc_video.mov",
    name = "DMC Video",
    duration_frames = 500,
    fps_numerator = 30,
    fps_denominator = 1
})
media:save(db)

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

-- Helper: create a master clip with source sequence
local function create_master_clip(id, name)
    -- Create source sequence for the master clip
    local source_seq = Sequence.create(name .. " (Source)", "project",
        {fps_numerator = 30, fps_denominator = 1}, 1920, 1080,
        {id = id .. "_src_seq", kind = "master"})
    assert(source_seq:save(), "Failed to save source sequence")

    -- Create video track in source sequence
    local src_track = Track.create_video("Video 1", source_seq.id, {id = id .. "_src_track", index = 1})
    assert(src_track:save(), "Failed to save source track")

    -- Create the master clip
    local clip = Clip.create(name, "media_dmc", {
        id = id,
        project_id = "project",
        clip_kind = "master",
        source_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        enabled = true,
        fps_numerator = 30,
        fps_denominator = 1
    })
    assert(clip:save(db), "Failed to save master clip " .. id)

    -- Create child clip in source sequence
    local child = Clip.create(name .. " (Video)", "media_dmc", {
        id = id .. "_child",
        project_id = "project",
        track_id = src_track.id,
        parent_clip_id = id,
        owner_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        enabled = true,
        fps_numerator = 30,
        fps_denominator = 1
    })
    assert(child:save(db), "Failed to save child clip")

    return clip
end

-- Helper: check if clip exists
local function clip_exists(clip_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count > 0
end

-- Helper: check if sequence exists
local function sequence_exists(seq_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM sequences WHERE id = ?")
    stmt:bind_value(1, seq_id)
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count > 0
end

-- Helper: reset test data
local function reset_test_data()
    db:exec("DELETE FROM clips")
    db:exec("DELETE FROM sequences WHERE id != 'sequence'")
    db:exec("DELETE FROM tracks WHERE sequence_id != 'sequence'")
end

-- =============================================================================
-- TEST 1: Basic delete master clip
-- =============================================================================
print("Test 1: Basic delete master clip")
reset_test_data()
create_master_clip("master_1", "Test Clip")

-- Verify clip exists before delete
assert(clip_exists("master_1"), "Master clip should exist before delete")
assert(clip_exists("master_1_child"), "Child clip should exist before delete")
assert(sequence_exists("master_1_src_seq"), "Source sequence should exist before delete")

local result = execute_command("DeleteMasterClip", {
    project_id = "project",
    master_clip_id = "master_1",
    master_clip_snapshot = {}  -- Will be populated by executor
})
assert(result.success, "DeleteMasterClip should succeed: " .. tostring(result.error_message))

-- Verify clip is deleted
assert(not clip_exists("master_1"), "Master clip should be deleted")
assert(not clip_exists("master_1_child"), "Child clip should be deleted")

-- =============================================================================
-- TEST 2: Undo restores master clip
-- =============================================================================
print("Test 2: Undo restores master clip")
local undo_result = undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- Verify clip is restored
assert(clip_exists("master_1"), "Master clip should be restored after undo")

-- =============================================================================
-- TEST 3: Redo re-deletes master clip
-- =============================================================================
print("Test 3: Redo re-deletes master clip")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

-- Verify clip is deleted again
assert(not clip_exists("master_1"), "Master clip should be deleted after redo")

-- =============================================================================
-- TEST 4: Cannot delete clip that is not a master clip
-- =============================================================================
print("Test 4: Cannot delete non-master clip")
reset_test_data()

-- Create a regular timeline clip (not a master)
local regular_clip = Clip.create("Regular Clip", "media_dmc", {
    id = "regular_clip",
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    clip_kind = "timeline",
    timeline_start = 0,
    duration = 100,
    source_in = 0,
    source_out = 100,
    enabled = true,
    fps_numerator = 30,
    fps_denominator = 1
})
assert(regular_clip:save(db), "Failed to save regular clip")

asserts._set_enabled_for_tests(false)
result = execute_command("DeleteMasterClip", {
    project_id = "project",
    master_clip_id = "regular_clip",
    master_clip_snapshot = {}
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DeleteMasterClip should fail for non-master clip")

-- Clip should still exist
assert(clip_exists("regular_clip"), "Regular clip should not be deleted")

-- =============================================================================
-- TEST 5: Cannot delete nonexistent clip
-- =============================================================================
print("Test 5: Cannot delete nonexistent clip")
asserts._set_enabled_for_tests(false)
result = execute_command("DeleteMasterClip", {
    project_id = "project",
    master_clip_id = "nonexistent_master",
    master_clip_snapshot = {}
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DeleteMasterClip should fail for nonexistent clip")

-- =============================================================================
-- TEST 6: Cannot delete master clip in use by timeline
-- =============================================================================
print("Test 6: Cannot delete master clip in use by timeline")
reset_test_data()
local master = create_master_clip("master_inuse", "In Use Clip")

-- Create a timeline clip that references this master
local timeline_clip = Clip.create("Timeline Instance", "media_dmc", {
    id = "timeline_instance",
    project_id = "project",
    track_id = "track_v1",
    parent_clip_id = "master_inuse",  -- References the master
    owner_sequence_id = "sequence",   -- In a different sequence than source
    clip_kind = "timeline",
    timeline_start = 0,
    duration = 100,
    source_in = 0,
    source_out = 100,
    enabled = true,
    fps_numerator = 30,
    fps_denominator = 1
})
assert(timeline_clip:save(db), "Failed to save timeline clip")

-- Try to delete - should fail because it's referenced
asserts._set_enabled_for_tests(false)
result = execute_command("DeleteMasterClip", {
    project_id = "project",
    master_clip_id = "master_inuse",
    master_clip_snapshot = {}
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DeleteMasterClip should fail when clip is in use")

-- Master clip should still exist
assert(clip_exists("master_inuse"), "Master clip should not be deleted when in use")

-- =============================================================================
-- TEST 7: Delete multiple master clips in sequence
-- =============================================================================
print("Test 7: Delete multiple master clips")
reset_test_data()
create_master_clip("master_a", "Clip A")
create_master_clip("master_b", "Clip B")
create_master_clip("master_c", "Clip C")

-- Delete all three
for _, id in ipairs({"master_a", "master_b", "master_c"}) do
    result = execute_command("DeleteMasterClip", {
        project_id = "project",
        master_clip_id = id,
        master_clip_snapshot = {}
    })
    assert(result.success, "DeleteMasterClip should succeed for " .. id)
end

-- Verify all deleted
assert(not clip_exists("master_a"), "master_a should be deleted")
assert(not clip_exists("master_b"), "master_b should be deleted")
assert(not clip_exists("master_c"), "master_c should be deleted")

-- Undo all three
for i = 1, 3 do
    undo_result = undo()
    assert(undo_result.success, "Undo " .. i .. " should succeed")
end

-- Verify all restored
assert(clip_exists("master_a"), "master_a should be restored")
assert(clip_exists("master_b"), "master_b should be restored")
assert(clip_exists("master_c"), "master_c should be restored")

-- =============================================================================
-- TEST 8: Error case - missing master_clip_id
-- =============================================================================
print("Test 8: Missing master_clip_id fails")
asserts._set_enabled_for_tests(false)
result = execute_command("DeleteMasterClip", {
    project_id = "project",
    master_clip_snapshot = {}
    -- No master_clip_id
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DeleteMasterClip without master_clip_id should fail")

print("\n✅ DeleteMasterClip command tests passed")
