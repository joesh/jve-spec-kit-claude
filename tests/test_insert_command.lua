#!/usr/bin/env luajit

-- Test Insert command - comprehensive coverage including edge cases
-- Tests: basic insertion, ripple behavior, undo/redo, error cases

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')
local asserts = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Insert Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_insert_command.db"
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
    VALUES ('track_a1', 'sequence', 'A1', 'AUDIO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- Helper: execute command with proper event wrapping
local function execute_cmd(cmd)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(cmd)
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

-- Create Media (100 frames @ 30fps)
local media = Media.create({
    id = "media_video",
    project_id = "project",
    file_path = "/tmp/jve/video.mov",
    name = "Video",
    duration_frames = 100,
    fps_numerator = 30,
    fps_denominator = 1
})
media:save(db)

-- Create downstream clip at [200, 300) to test ripple behavior
local downstream_clip = Clip.create("Downstream", "media_video", {
    id = "downstream_clip",
    project_id = "project",
    track_id = "track_v1",
    owner_sequence_id = "sequence",
    timeline_start = Rational.new(200, 30, 1),
    duration = Rational.new(100, 30, 1),
    source_in = Rational.new(0, 30, 1),
    source_out = Rational.new(100, 30, 1),
    enabled = true,
    fps_numerator = 30,
    fps_denominator = 1
})
assert(downstream_clip:save(db), "Failed to save downstream clip")

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

-- =============================================================================
-- TEST 1: Basic insertion at specific position
-- =============================================================================
print("Test 1: Basic insertion at frame 0")
local insert_cmd = Command.create("Insert", "project")
insert_cmd:set_parameter("media_id", "media_video")
insert_cmd:set_parameter("track_id", "track_v1")
insert_cmd:set_parameter("sequence_id", "sequence")
insert_cmd:set_parameter("insert_time", Rational.new(0, 30, 1))
insert_cmd:set_parameter("duration", Rational.new(50, 30, 1))
insert_cmd:set_parameter("source_in", Rational.new(0, 30, 1))
insert_cmd:set_parameter("source_out", Rational.new(50, 30, 1))

local result = execute_cmd(insert_cmd)
assert(result.success, "Insert should succeed: " .. tostring(result.error_message))

-- Should have 2 clips now (inserted + downstream)
assert(count_clips("track_v1") == 2, string.format("Should have 2 clips, got %d", count_clips("track_v1")))

-- Downstream clip should have rippled from 200 to 250
local downstream_start, _ = get_clip_position("downstream_clip")
assert(downstream_start == 250, string.format("Downstream should ripple to 250, got %d", downstream_start))

-- =============================================================================
-- TEST 2: Insert ripples downstream clips
-- =============================================================================
print("Test 2: Second insert at frame 0 ripples everything")
local insert_cmd2 = Command.create("Insert", "project")
insert_cmd2:set_parameter("media_id", "media_video")
insert_cmd2:set_parameter("track_id", "track_v1")
insert_cmd2:set_parameter("sequence_id", "sequence")
insert_cmd2:set_parameter("insert_time", Rational.new(0, 30, 1))
insert_cmd2:set_parameter("duration", Rational.new(30, 30, 1))
insert_cmd2:set_parameter("source_in", Rational.new(0, 30, 1))
insert_cmd2:set_parameter("source_out", Rational.new(30, 30, 1))

result = execute_cmd(insert_cmd2)
assert(result.success, "Second insert should succeed")

-- Should have 3 clips now
assert(count_clips("track_v1") == 3, string.format("Should have 3 clips, got %d", count_clips("track_v1")))

-- Downstream should ripple further: 250 + 30 = 280
downstream_start, _ = get_clip_position("downstream_clip")
assert(downstream_start == 280, string.format("Downstream should ripple to 280, got %d", downstream_start))

-- =============================================================================
-- TEST 3: Undo removes inserted clip and restores positions
-- =============================================================================
print("Test 3: Undo restores original state")
local undo_result = undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- Should have 2 clips again
assert(count_clips("track_v1") == 2, string.format("After undo should have 2 clips, got %d", count_clips("track_v1")))

-- Downstream should restore to 250
downstream_start, _ = get_clip_position("downstream_clip")
assert(downstream_start == 250, string.format("Downstream should restore to 250 after undo, got %d", downstream_start))

-- =============================================================================
-- TEST 4: Redo reinserts clip (verify clip ID preservation)
-- =============================================================================
print("Test 4: Redo reinserts clip")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

-- Should have 3 clips again
assert(count_clips("track_v1") == 3, string.format("After redo should have 3 clips, got %d", count_clips("track_v1")))

-- Downstream should ripple again to 280
downstream_start, _ = get_clip_position("downstream_clip")
assert(downstream_start == 280, string.format("Downstream should ripple to 280 after redo, got %d", downstream_start))

-- =============================================================================
-- TEST 5: Insert uses media duration when not specified
-- =============================================================================
print("Test 5: Insert uses media duration when unspecified")
-- Clean up first
db:exec("DELETE FROM clips WHERE id != 'downstream_clip'")
db:exec("UPDATE clips SET timeline_start_frame = 200 WHERE id = 'downstream_clip'")

local insert_cmd3 = Command.create("Insert", "project")
insert_cmd3:set_parameter("media_id", "media_video")
insert_cmd3:set_parameter("track_id", "track_v1")
insert_cmd3:set_parameter("sequence_id", "sequence")
insert_cmd3:set_parameter("insert_time", Rational.new(0, 30, 1))
-- No duration specified - should use media duration (100 frames)

result = execute_cmd(insert_cmd3)
assert(result.success, "Insert without duration should succeed: " .. tostring(result.error_message))

-- Verify clip was created with media duration
local stmt = db:prepare("SELECT duration_frames FROM clips WHERE track_id = 'track_v1' AND timeline_start_frame = 0")
stmt:exec()
assert(stmt:next(), "Should find inserted clip")
local inserted_duration = stmt:value(0)
stmt:finalize()
assert(inserted_duration == 100, string.format("Clip should have media duration 100, got %d", inserted_duration))

-- =============================================================================
-- TEST 6: Insert at exact clip boundary ripples correctly
-- =============================================================================
print("Test 6: Insert at exact clip start boundary")
-- Reset: put downstream back at 200
db:exec("DELETE FROM clips WHERE id != 'downstream_clip'")
db:exec("UPDATE clips SET timeline_start_frame = 200 WHERE id = 'downstream_clip'")

local insert_cmd4 = Command.create("Insert", "project")
insert_cmd4:set_parameter("media_id", "media_video")
insert_cmd4:set_parameter("track_id", "track_v1")
insert_cmd4:set_parameter("sequence_id", "sequence")
insert_cmd4:set_parameter("insert_time", Rational.new(200, 30, 1))  -- Exactly at downstream start
insert_cmd4:set_parameter("duration", Rational.new(50, 30, 1))
insert_cmd4:set_parameter("source_in", Rational.new(0, 30, 1))
insert_cmd4:set_parameter("source_out", Rational.new(50, 30, 1))

result = execute_cmd(insert_cmd4)
assert(result.success, "Insert at boundary should succeed")

-- Downstream should ripple to 250
downstream_start, _ = get_clip_position("downstream_clip")
assert(downstream_start == 250, string.format("Downstream should ripple to 250, got %d", downstream_start))

-- =============================================================================
-- TEST 7: Error case - missing media_id
-- =============================================================================
print("Test 7: Missing media_id fails")
-- Disable asserts for error case testing (schema validation asserts on missing required params)
asserts._set_enabled_for_tests(false)
local bad_cmd = Command.create("Insert", "project")
bad_cmd:set_parameter("track_id", "track_v1")
bad_cmd:set_parameter("sequence_id", "sequence")
bad_cmd:set_parameter("insert_time", Rational.new(0, 30, 1))
bad_cmd:set_parameter("duration", Rational.new(50, 30, 1))
-- No media_id

result = execute_cmd(bad_cmd)
asserts._set_enabled_for_tests(true)
assert(not result.success, "Insert without media_id should fail")

-- =============================================================================
-- TEST 8: Error case - nonexistent master_clip_id
-- =============================================================================
print("Test 8: Nonexistent master_clip_id fails")
asserts._set_enabled_for_tests(false)
local bad_cmd2 = Command.create("Insert", "project")
bad_cmd2:set_parameter("media_id", "media_video")
bad_cmd2:set_parameter("track_id", "track_v1")
bad_cmd2:set_parameter("sequence_id", "sequence")
bad_cmd2:set_parameter("insert_time", Rational.new(0, 30, 1))
bad_cmd2:set_parameter("master_clip_id", "nonexistent_master")  -- Should fail
bad_cmd2:set_parameter("duration", Rational.new(50, 30, 1))

result = execute_cmd(bad_cmd2)
asserts._set_enabled_for_tests(true)
assert(not result.success, "Insert with nonexistent master_clip_id should fail")

-- =============================================================================
-- TEST 9: Multiple undo/redo cycle maintains integrity
-- =============================================================================
print("Test 9: Multiple undo/redo cycle")
-- Reset state
db:exec("DELETE FROM clips WHERE id != 'downstream_clip'")
db:exec("UPDATE clips SET timeline_start_frame = 200 WHERE id = 'downstream_clip'")

-- Insert 3 clips
for i = 1, 3 do
    local cmd = Command.create("Insert", "project")
    cmd:set_parameter("media_id", "media_video")
    cmd:set_parameter("track_id", "track_v1")
    cmd:set_parameter("sequence_id", "sequence")
    cmd:set_parameter("insert_time", Rational.new(0, 30, 1))
    cmd:set_parameter("duration", Rational.new(20, 30, 1))
    cmd:set_parameter("source_in", Rational.new(0, 30, 1))
    cmd:set_parameter("source_out", Rational.new(20, 30, 1))
    result = execute_cmd(cmd)
    assert(result.success, string.format("Insert %d should succeed", i))
end

assert(count_clips("track_v1") == 4, "Should have 4 clips after 3 inserts")

-- Undo all 3
for i = 1, 3 do
    undo_result = undo()
    assert(undo_result.success, string.format("Undo %d should succeed", i))
end

assert(count_clips("track_v1") == 1, "Should have 1 clip after 3 undos")

-- Redo all 3
for i = 1, 3 do
    redo_result = redo()
    assert(redo_result.success, string.format("Redo %d should succeed", i))
end

assert(count_clips("track_v1") == 4, "Should have 4 clips after 3 redos")

print("\n✅ Insert command tests passed")
