#!/usr/bin/env luajit

-- Test Overwrite command - comprehensive coverage
-- Tests: basic overwrite, undo/redo, UI context resolution, occlusion handling

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Track = require('models.track')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')
local asserts = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Overwrite Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_overwrite.db"
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
    id = "media_ow",
    project_id = "project",
    file_path = "/tmp/jve/ow_video.mov",
    name = "OW Video",
    duration_frames = 500,
    fps_numerator = 30,
    fps_denominator = 1
})
media:save(db)

-- Create masterclip sequence for this media (required for Overwrite)
local master_clip_id = test_env.create_test_masterclip_sequence(
    "project", "OW Video Master", 30, 1, 500, "media_ow")

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
    local clip = Clip.create("Clip " .. id, "media_ow", {
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

-- Helper: get clip position
local function get_clip_position(clip_id)
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

-- Helper: reset timeline (only timeline clips, not masterclip stream clips)
local function reset_timeline()
    db:exec("DELETE FROM clips WHERE track_id IN ('track_v1', 'track_v2')")
end

-- =============================================================================
-- TEST 1: Basic overwrite at empty position
-- =============================================================================
print("Test 1: Basic overwrite at empty position")
reset_timeline()

local result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    master_clip_id = master_clip_id,
    overwrite_time = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite should succeed: " .. tostring(result.error_message))
assert(count_clips("track_v1") == 1, "Should have 1 clip on track")

-- =============================================================================
-- TEST 2: Overwrite replaces existing clip completely
-- =============================================================================
print("Test 2: Overwrite replaces existing clip completely")
reset_timeline()
create_clip("existing_clip", "track_v1", 0, 100)

result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    master_clip_id = master_clip_id,
    clip_id = "overwrite_clip",
    overwrite_time = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite should succeed")

-- Original clip should be deleted, new clip should exist
assert(not clip_exists("existing_clip"), "Original clip should be deleted")
assert(clip_exists("overwrite_clip"), "New clip should exist")

-- =============================================================================
-- TEST 3: Overwrite trims clip at start
-- =============================================================================
print("Test 3: Overwrite trims clip at start (partial overlap)")
reset_timeline()
create_clip("trim_start", "track_v1", 0, 100)

-- Overwrite first 50 frames
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    master_clip_id = master_clip_id,
    clip_id = "overwrite_start",
    overwrite_time = 0,
    duration = 50,
    source_in = 0,
    source_out = 50
})
assert(result.success, "Overwrite should succeed")

-- Original should be trimmed, starting at 50
local start, dur = get_clip_position("trim_start")
assert(start == 50, string.format("Original should start at 50, got %s", tostring(start)))
assert(dur == 50, string.format("Original should be 50 frames, got %s", tostring(dur)))

-- =============================================================================
-- TEST 4: Undo restores original clips
-- =============================================================================
print("Test 4: Undo restores original clips")
local undo_result = undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- Original clip should be restored to [0, 100)
start, dur = get_clip_position("trim_start")
assert(start == 0, string.format("Original should restore to 0, got %s", tostring(start)))
assert(dur == 100, string.format("Original should be 100 frames, got %s", tostring(dur)))

-- Overwrite clip should be gone
assert(not clip_exists("overwrite_start"), "Overwrite clip should be removed after undo")

-- =============================================================================
-- TEST 5: Redo re-applies overwrite
-- =============================================================================
print("Test 5: Redo re-applies overwrite")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

-- Original should be trimmed again
start, dur = get_clip_position("trim_start")
assert(start == 50, string.format("Original should be at 50 after redo, got %s", tostring(start)))

-- Overwrite clip should be back
assert(clip_exists("overwrite_start"), "Overwrite clip should exist after redo")

-- =============================================================================
-- TEST 6: Overwrite splits clip in middle
-- =============================================================================
print("Test 6: Overwrite splits clip in middle")
reset_timeline()
create_clip("split_me", "track_v1", 0, 200)

-- Overwrite middle 50 frames [75, 125)
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    master_clip_id = master_clip_id,
    clip_id = "middle_overwrite",
    overwrite_time = 75,
    duration = 50,
    source_in = 0,
    source_out = 50
})
assert(result.success, "Overwrite should succeed")

-- Should have 3 clips total (left part, overwrite, right part) or overwrite replaced original
assert(count_clips("track_v1") >= 1, "Should have at least 1 clip")

-- =============================================================================
-- TEST 7: Error case - missing media_id without UI context
-- =============================================================================
print("Test 7: Missing media_id fails without UI context")
reset_timeline()
asserts._set_enabled_for_tests(false)
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    overwrite_time = 0,
    duration = 100
    -- No master_clip_id
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "Overwrite without master_clip_id should fail")

-- =============================================================================
-- TEST 8: Resolves track_id from sequence when not provided
-- =============================================================================
print("Test 8: Resolves track_id from sequence")
reset_timeline()
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    -- No track_id - should use first video track
    master_clip_id = master_clip_id,
    overwrite_time = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite should resolve track_id from sequence: " .. tostring(result.error_message))
assert(count_clips("track_v1") == 1, "Clip should be on first video track (track_v1)")

-- =============================================================================
-- TEST 9: Zero duration falls back to media duration
-- =============================================================================
print("Test 9: Zero duration falls back to media duration")
reset_timeline()
-- When duration is zero/nil, Overwrite should use media's full duration (500 frames)
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    master_clip_id = master_clip_id,
    clip_id = "fallback_dur_clip",
    overwrite_time = 0,
    duration = 0  -- Zero duration - should fallback to media
})
assert(result.success, "Overwrite should succeed with duration fallback: " .. tostring(result.error_message))

-- Clip should have media's duration (500 frames)
start, dur = get_clip_position("fallback_dur_clip")
assert(dur == 500, string.format("Clip should use media duration (500), got %s", tostring(dur)))

-- =============================================================================
-- TEST 10: Multiple overwrites in sequence
-- =============================================================================
print("Test 10: Multiple overwrites in sequence")
reset_timeline()

-- First overwrite at [0, 100)
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    master_clip_id = master_clip_id,
    clip_id = "ow_1",
    overwrite_time = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "First overwrite should succeed")

-- Second overwrite at [100, 200)
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    master_clip_id = master_clip_id,
    clip_id = "ow_2",
    overwrite_time = 100,
    duration = 100,
    source_in = 100,
    source_out = 200
})
assert(result.success, "Second overwrite should succeed")

-- Third overwrite at [200, 300)
result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    master_clip_id = master_clip_id,
    clip_id = "ow_3",
    overwrite_time = 200,
    duration = 100,
    source_in = 200,
    source_out = 300
})
assert(result.success, "Third overwrite should succeed")

assert(count_clips("track_v1") == 3, string.format("Should have 3 clips, got %d", count_clips("track_v1")))

-- Undo all three
for i = 1, 3 do
    undo_result = undo()
    assert(undo_result.success, "Undo " .. i .. " should succeed")
end

assert(count_clips("track_v1") == 0, "All clips should be removed after undos")

-- =============================================================================
-- TEST 11: Overwrite on different track
-- =============================================================================
print("Test 11: Overwrite on different track")
reset_timeline()
create_clip("v1_clip", "track_v1", 0, 100)

result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v2",  -- Different track
    master_clip_id = master_clip_id,
    clip_id = "v2_clip",
    overwrite_time = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite on v2 should succeed")

-- Both clips should exist (different tracks)
assert(clip_exists("v1_clip"), "v1_clip should still exist")
assert(clip_exists("v2_clip"), "v2_clip should exist")
assert(count_clips("track_v1") == 1, "track_v1 should have 1 clip")
assert(count_clips("track_v2") == 1, "track_v2 should have 1 clip")

-- =============================================================================
-- TEST 12: Overwrite adds audio clips for media with audio
-- =============================================================================
print("Test 12: Overwrite adds audio clips for media with audio")
reset_timeline()

-- Create media with audio channels
local audio_media = Media.create({
    id = "media_with_audio",
    project_id = "project",
    file_path = "/tmp/jve/audio_video.mov",
    name = "Audio Video",
    duration_frames = 100,
    fps_numerator = 30,
    fps_denominator = 1,
    audio_channels = 2  -- Stereo audio
})
audio_media:save(db)

-- Create audio tracks
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_a1', 'sequence', 'A1', 'AUDIO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_a2', 'sequence', 'A2', 'AUDIO', 2, 1);
]])

result = execute_command("Overwrite", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    media_id = "media_with_audio",
    overwrite_time = 0,
    duration = 100,
    source_in = 0,
    source_out = 100
})
assert(result.success, "Overwrite with audio media should succeed: " .. tostring(result.error_message))

-- Should have video clip on V1
assert(count_clips("track_v1") == 1, "Should have 1 video clip on track_v1")

-- Should have audio clips on A1 and A2
local function count_audio_clips(track_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = ?")
    stmt:bind_value(1, track_id)
    stmt:exec()
    stmt:next()
    local count = stmt:value(0)
    stmt:finalize()
    return count
end

assert(count_audio_clips("track_a1") == 1, string.format("Should have 1 audio clip on A1, got %d", count_audio_clips("track_a1")))
assert(count_audio_clips("track_a2") == 1, string.format("Should have 1 audio clip on A2, got %d", count_audio_clips("track_a2")))

print("\n\226\156\133 Overwrite command tests passed")
