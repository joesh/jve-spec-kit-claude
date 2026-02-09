#!/usr/bin/env luajit

-- Test DeleteSequence command - comprehensive coverage
-- Tests: basic delete, undo/redo, default sequence protection, master sequence protection

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Sequence = require('models.sequence')
local Track = require('models.track')
local command_manager = require('core.command_manager')
local asserts = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== DeleteSequence Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_delete_sequence.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project and default sequence
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('default_sequence', 'project', 'Default Sequence', 'timeline', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('default_track', 'default_sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('default_sequence', 'project')

-- Create Media
local media = Media.create({
    id = "media_ds",
    project_id = "project",
    file_path = "/tmp/jve/ds_video.mov",
    name = "DS Video",
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

-- Helper: create a timeline sequence with tracks and clips
local function create_test_sequence(id, name)
    local seq = Sequence.create(name, "project",
        {fps_numerator = 30, fps_denominator = 1}, 1920, 1080,
        {id = id, kind = "timeline"})
    assert(seq:save(), "Failed to save sequence " .. id)

    local track = Track.create_video("V1", id, {id = id .. "_track", index = 1})
    assert(track:save(), "Failed to save track")

    local clip = Clip.create("Test Clip", "media_ds", {
        id = id .. "_clip",
        project_id = "project",
        track_id = track.id,
        owner_sequence_id = id,
        timeline_start = 0,
        duration = 100,
        source_in = 0,
        source_out = 100,
        enabled = true,
        fps_numerator = 30,
        fps_denominator = 1
    })
    assert(clip:save(db), "Failed to save clip")

    return seq
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

-- Helper: check if track exists
local function track_exists(track_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM tracks WHERE id = ?")
    stmt:bind_value(1, track_id)
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count > 0
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

-- Helper: reset test sequences (keep default_sequence)
local function reset_test_sequences()
    db:exec("DELETE FROM clips WHERE owner_sequence_id != 'default_sequence'")
    db:exec("DELETE FROM tracks WHERE sequence_id != 'default_sequence'")
    db:exec("DELETE FROM sequences WHERE id != 'default_sequence'")
end

-- =============================================================================
-- TEST 1: Basic delete sequence
-- =============================================================================
print("Test 1: Basic delete sequence")
reset_test_sequences()
create_test_sequence("seq_1", "Test Sequence 1")

-- Verify exists before delete
assert(sequence_exists("seq_1"), "Sequence should exist before delete")
assert(track_exists("seq_1_track"), "Track should exist before delete")
assert(clip_exists("seq_1_clip"), "Clip should exist before delete")

local result = execute_command("DeleteSequence", {
    project_id = "project",
    sequence_id = "seq_1"
})
assert(result.success, "DeleteSequence should succeed: " .. tostring(result.error_message))

-- Verify all deleted
assert(not sequence_exists("seq_1"), "Sequence should be deleted")
assert(not track_exists("seq_1_track"), "Track should be deleted")
assert(not clip_exists("seq_1_clip"), "Clip should be deleted")

-- =============================================================================
-- TEST 2: Undo restores sequence
-- =============================================================================
print("Test 2: Undo restores sequence")
local undo_result = undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- Verify restored
assert(sequence_exists("seq_1"), "Sequence should be restored")
assert(track_exists("seq_1_track"), "Track should be restored")
assert(clip_exists("seq_1_clip"), "Clip should be restored")

-- =============================================================================
-- TEST 3: Redo re-deletes sequence
-- =============================================================================
print("Test 3: Redo re-deletes sequence")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

-- Verify deleted again
assert(not sequence_exists("seq_1"), "Sequence should be deleted after redo")

-- =============================================================================
-- TEST 4: Cannot delete default_sequence
-- =============================================================================
print("Test 4: Cannot delete default_sequence")
asserts._set_enabled_for_tests(false)
result = execute_command("DeleteSequence", {
    project_id = "project",
    sequence_id = "default_sequence"
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DeleteSequence should fail for default_sequence")

-- default_sequence should still exist
assert(sequence_exists("default_sequence"), "Default sequence should not be deleted")

-- =============================================================================
-- TEST 5: Cannot delete master sequence
-- =============================================================================
print("Test 5: Cannot delete master sequence")
reset_test_sequences()

-- Create a master sequence
local master_seq = Sequence.create("Master Sequence", "project",
    {fps_numerator = 30, fps_denominator = 1}, 1920, 1080,
    {id = "master_seq", kind = "master"})
assert(master_seq:save(), "Failed to save master sequence")

asserts._set_enabled_for_tests(false)
result = execute_command("DeleteSequence", {
    project_id = "project",
    sequence_id = "master_seq"
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DeleteSequence should fail for master sequence")

-- Master sequence should still exist
assert(sequence_exists("master_seq"), "Master sequence should not be deleted")

-- =============================================================================
-- TEST 6: Cannot delete nonexistent sequence
-- =============================================================================
print("Test 6: Cannot delete nonexistent sequence")
asserts._set_enabled_for_tests(false)
result = execute_command("DeleteSequence", {
    project_id = "project",
    sequence_id = "nonexistent_seq"
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DeleteSequence should fail for nonexistent sequence")

-- =============================================================================
-- TEST 7: Delete sequence with multiple tracks and clips
-- =============================================================================
print("Test 7: Delete sequence with multiple tracks and clips")
reset_test_sequences()

-- Create sequence with multiple tracks
local seq = Sequence.create("Multi Track Seq", "project",
    {fps_numerator = 30, fps_denominator = 1}, 1920, 1080,
    {id = "multi_seq", kind = "timeline"})
assert(seq:save(), "Failed to save sequence")

-- Create multiple video tracks
for i = 1, 3 do
    local track = Track.create_video("V" .. i, "multi_seq", {id = "multi_track_" .. i, index = i})
    assert(track:save(), "Failed to save track " .. i)

    -- Create clips on each track
    for j = 1, 2 do
        local clip = Clip.create("Clip " .. i .. "-" .. j, "media_ds", {
            id = "multi_clip_" .. i .. "_" .. j,
            project_id = "project",
            track_id = "multi_track_" .. i,
            owner_sequence_id = "multi_seq",
            timeline_start = (j-1) * 100,
            duration = 100,
            source_in = 0,
            source_out = 100,
            enabled = true,
            fps_numerator = 30,
            fps_denominator = 1
        })
        assert(clip:save(db), "Failed to save clip")
    end
end

-- Verify setup
assert(sequence_exists("multi_seq"), "Multi sequence should exist")

-- Count tracks and clips before
local stmt = db:prepare("SELECT COUNT(*) FROM tracks WHERE sequence_id = 'multi_seq'")
stmt:exec(); stmt:next()
local tracks_before = stmt:value(0)
stmt:finalize()
assert(tracks_before == 3, string.format("Should have 3 tracks, got %d", tracks_before))

-- Delete
result = execute_command("DeleteSequence", {
    project_id = "project",
    sequence_id = "multi_seq"
})
assert(result.success, "DeleteSequence should succeed")

-- Verify all deleted
assert(not sequence_exists("multi_seq"), "Sequence should be deleted")

stmt = db:prepare("SELECT COUNT(*) FROM tracks WHERE sequence_id = 'multi_seq'")
stmt:exec(); stmt:next()
local tracks_after = stmt:value(0)
stmt:finalize()
assert(tracks_after == 0, "All tracks should be deleted")

-- =============================================================================
-- TEST 8: Error case - missing sequence_id
-- =============================================================================
print("Test 8: Missing sequence_id fails")
asserts._set_enabled_for_tests(false)
result = execute_command("DeleteSequence", {
    project_id = "project"
    -- No sequence_id
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DeleteSequence without sequence_id should fail")

-- =============================================================================
-- TEST 9: Delete multiple sequences in sequence
-- =============================================================================
print("Test 9: Delete multiple sequences")
reset_test_sequences()
create_test_sequence("seq_a", "Sequence A")
create_test_sequence("seq_b", "Sequence B")
create_test_sequence("seq_c", "Sequence C")

-- Delete all three
for _, id in ipairs({"seq_a", "seq_b", "seq_c"}) do
    result = execute_command("DeleteSequence", {
        project_id = "project",
        sequence_id = id
    })
    assert(result.success, "DeleteSequence should succeed for " .. id)
end

-- Verify all deleted
assert(not sequence_exists("seq_a"), "seq_a should be deleted")
assert(not sequence_exists("seq_b"), "seq_b should be deleted")
assert(not sequence_exists("seq_c"), "seq_c should be deleted")

-- Undo all three
for i = 1, 3 do
    undo_result = undo()
    assert(undo_result.success, "Undo " .. i .. " should succeed")
end

-- Verify all restored
assert(sequence_exists("seq_a"), "seq_a should be restored")
assert(sequence_exists("seq_b"), "seq_b should be restored")
assert(sequence_exists("seq_c"), "seq_c should be restored")

print("\n✅ DeleteSequence command tests passed")
