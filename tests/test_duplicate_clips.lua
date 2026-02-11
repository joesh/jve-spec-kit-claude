#!/usr/bin/env luajit

-- Test DuplicateClips command - comprehensive coverage
-- Tests: basic duplicate, cross-track duplicate, undo/redo, delta offset, error cases

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local command_manager = require('core.command_manager')
local asserts = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== DuplicateClips Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_duplicate_clips.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Disable overlap triggers for cleaner testing
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

-- Insert Project/Sequence (30fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v2', 'sequence', 'V2', 'VIDEO', 2, 1);
]])

command_manager.init('sequence', 'project')

-- Create Media (500 frames @ 30fps)
local media = Media.create({
    id = "media_dup",
    project_id = "project",
    file_path = "/tmp/jve/dup_video.mov",
    name = "Dup Video",
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

-- Helper: create a clip
local function create_clip(id, track_id, start_frame, duration_frames)
    local clip = Clip.create("Clip " .. id, "media_dup", {
        id = id,
        project_id = "project",
        track_id = track_id,
        owner_sequence_id = "sequence",
        timeline_start = start_frame,
        duration = duration_frames,
        source_in = 0,
        source_out = duration_frames,
        enabled = true,
        fps_numerator = 30,
        fps_denominator = 1
    })
    assert(clip:save(db), "Failed to save clip " .. id)
    return clip
end

-- Helper: count clips on track
local function count_clips(track_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = ?")
    stmt:bind_value(1, track_id)
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

-- Helper: get clip position
local function get_clip_position(clip_id) -- luacheck: ignore 211
    local stmt = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    stmt:exec()
    if stmt:next() then
        local start = stmt:value(0)
        local dur = stmt:value(1)
        stmt:finalize()
        return start, dur
    end
    stmt:finalize()
    return nil, nil
end

-- Helper: reset timeline
local function reset_timeline()
    db:exec("DELETE FROM clips")
end

-- =============================================================================
-- TEST 1: Basic duplicate - single clip to same track
-- =============================================================================
print("Test 1: Basic duplicate single clip")
reset_timeline()
create_clip("clip_a", "track_v1", 0, 100)

local result = execute_command("DuplicateClips", {
    project_id = "project",
    sequence_id = "sequence",
    clip_ids = {"clip_a"},
    anchor_clip_id = "clip_a",
    target_track_id = "track_v1",
    delta_frames = 100  -- Offset by 100 frames
})
assert(result.success, "DuplicateClips should succeed: " .. tostring(result.error_message))

-- Should have 2 clips now
assert(count_clips("track_v1") == 2, string.format("Should have 2 clips on v1, got %d", count_clips("track_v1")))

-- =============================================================================
-- TEST 2: Duplicate to different track
-- =============================================================================
print("Test 2: Duplicate to different track")
reset_timeline()
create_clip("clip_a", "track_v1", 0, 100)

result = execute_command("DuplicateClips", {
    project_id = "project",
    sequence_id = "sequence",
    clip_ids = {"clip_a"},
    anchor_clip_id = "clip_a",
    target_track_id = "track_v2",  -- Different track
    delta_frames = 0
})
assert(result.success, "DuplicateClips to different track should succeed")

-- v1 should have 1, v2 should have 1
assert(count_clips("track_v1") == 1, "v1 should still have 1 clip")
assert(count_clips("track_v2") == 1, "v2 should have 1 new clip")

-- =============================================================================
-- TEST 3: Duplicate multiple clips at once
-- =============================================================================
print("Test 3: Duplicate multiple clips")
reset_timeline()
create_clip("clip_a", "track_v1", 0, 100)
create_clip("clip_b", "track_v1", 100, 100)
create_clip("clip_c", "track_v1", 200, 100)

result = execute_command("DuplicateClips", {
    project_id = "project",
    sequence_id = "sequence",
    clip_ids = {"clip_a", "clip_b", "clip_c"},
    anchor_clip_id = "clip_a",
    target_track_id = "track_v2",
    delta_frames = 0
})
assert(result.success, "DuplicateClips multiple should succeed")

-- v2 should have 3 new clips
assert(count_clips("track_v2") == 3, string.format("v2 should have 3 clips, got %d", count_clips("track_v2")))

-- =============================================================================
-- TEST 4: Undo removes duplicated clips
-- =============================================================================
print("Test 4: Undo removes duplicated clips")
local before_undo = count_clips("track_v2")
assert(before_undo == 3, "Should have 3 clips before undo")

local undo_result = undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

local after_undo = count_clips("track_v2")
assert(after_undo == 0, string.format("Undo should remove duplicated clips: before=%d, after=%d", before_undo, after_undo))

-- =============================================================================
-- TEST 5: Redo re-creates duplicated clips
-- =============================================================================
print("Test 5: Redo re-creates duplicated clips")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

local after_redo = count_clips("track_v2")
assert(after_redo == 3, string.format("Redo should restore clips: got %d", after_redo))

-- =============================================================================
-- TEST 6: Duplicate with delta offset
-- =============================================================================
print("Test 6: Duplicate with delta offset")
reset_timeline()
create_clip("clip_a", "track_v1", 0, 100)

result = execute_command("DuplicateClips", {
    project_id = "project",
    sequence_id = "sequence",
    clip_ids = {"clip_a"},
    anchor_clip_id = "clip_a",
    target_track_id = "track_v2",
    delta_frames = 50  -- 50 frame offset
})
assert(result.success, "DuplicateClips with offset should succeed")

-- Find the new clip on v2
local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE track_id = 'track_v2' LIMIT 1")
stmt:exec()
assert(stmt:next(), "Should find duplicated clip")
local dup_start = stmt:value(0)
stmt:finalize()

-- Original starts at 0, duplicate should start at 50
assert(dup_start == 50, string.format("Duplicate should be at 50, got %d", dup_start))

-- =============================================================================
-- TEST 7: Error case - missing clip_ids
-- =============================================================================
print("Test 7: Missing clip_ids fails")
asserts._set_enabled_for_tests(false)
result = execute_command("DuplicateClips", {
    project_id = "project",
    sequence_id = "sequence",
    anchor_clip_id = "clip_a",
    target_track_id = "track_v1"
    -- No clip_ids
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DuplicateClips without clip_ids should fail")

-- =============================================================================
-- TEST 8: Error case - missing target_track_id
-- =============================================================================
print("Test 8: Missing target_track_id fails")
asserts._set_enabled_for_tests(false)
result = execute_command("DuplicateClips", {
    project_id = "project",
    sequence_id = "sequence",
    clip_ids = {"clip_a"},
    anchor_clip_id = "clip_a"
    -- No target_track_id
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "DuplicateClips without target_track_id should fail")

-- =============================================================================
-- TEST 9: Duplicate preserves clip properties
-- =============================================================================
print("Test 9: Duplicate preserves clip properties")
reset_timeline()
create_clip("clip_orig", "track_v1", 0, 100)

result = execute_command("DuplicateClips", {
    project_id = "project",
    sequence_id = "sequence",
    clip_ids = {"clip_orig"},
    anchor_clip_id = "clip_orig",
    target_track_id = "track_v2",
    delta_frames = 0
})
assert(result.success, "DuplicateClips should succeed")

-- Find the duplicated clip
stmt = db:prepare([[
    SELECT duration_frames, source_in_frame, source_out_frame, media_id
    FROM clips WHERE track_id = 'track_v2' LIMIT 1
]])
stmt:exec()
assert(stmt:next(), "Should find duplicated clip")
local dup_duration = stmt:value(0)
local dup_source_in = stmt:value(1)
local dup_source_out = stmt:value(2)
local dup_media_id = stmt:value(3)
stmt:finalize()

-- Verify properties match original
assert(dup_duration == 100, string.format("Duration should be 100, got %d", dup_duration))
assert(dup_media_id == "media_dup", "Media ID should match")
assert(dup_source_in == 0, "Source in should be 0")
assert(dup_source_out == 100, "Source out should be 100")

print("\n✅ DuplicateClips command tests passed")
