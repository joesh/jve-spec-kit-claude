#!/usr/bin/env luajit

-- Test Insert command - comprehensive coverage including edge cases
-- Tests: basic insertion, ripple behavior, undo/redo, error cases

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_manager = require('core.command_manager')
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
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('project', 'Test Project', 'resample', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 'nested', 30, 1, 48000, 1920, 1080, %d, %d);
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
-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media_video")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
local _Sequence_for_master = require("models.sequence")
local MC_TEST = _Sequence_for_master.ensure_master("media_video", "project")

-- Create masterclip sequence for this media (required for Insert)
local nested_sequence_id = test_env.create_test_masterclip_sequence(
    "project", "Video Master", 30, 1, 100, "media_video")

-- Create downstream clip at [200, 300) to test ripple behavior
local downstream_clip = Clip.create({
        name = "Downstream",
        id = "downstream_clip",
        project_id = "project",
        track_id = "track_v1",
        owner_sequence_id = "sequence",
        nested_sequence_id = MC_TEST,
        timeline_start_frame = 200,
        duration_frames = 100,
        source_in_frame = 0,
        source_out_frame = 100,
        enabled = true,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
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

-- Helper: set marks on masterclip sequence to define source subrange
local Sequence = require("models.sequence")
local function set_masterclip_marks(mc_id, mark_in, mark_out)
    local mc_seq = assert(Sequence.load(mc_id), "set_masterclip_marks: not found")
    mc_seq.mark_in = mark_in
    mc_seq.mark_out = mark_out
    assert(mc_seq:save(), "set_masterclip_marks: save failed")
end

-- =============================================================================
-- TEST 1: Basic insertion at specific position
-- =============================================================================
print("Test 1: Basic insertion at frame 0")
set_masterclip_marks(nested_sequence_id, 0, 50)
local insert_cmd = Command.create("Insert", "project")
insert_cmd:set_parameter("nested_sequence_id", nested_sequence_id)
insert_cmd:set_parameter("target_video_track_id", "track_v1")
insert_cmd:set_parameter("sequence_id", "sequence")
insert_cmd:set_parameter("timeline_start_frame", 0)

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
set_masterclip_marks(nested_sequence_id, 0, 30)
local insert_cmd2 = Command.cr, "project")
insert_cmd2:set_parameter("nested_sequence_id", nested_sequence_id)
insert_cmd2:set_parameter("target_video_track_id", "track_v1")
insert_cmd2:set_parameter("sequence_id", "sequence")
insert_cmd2:set_parameter("timeline_start_frame", 0)rt_frame", 0)

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
db:exec("DELETE FROM clips WHERE track_id = 'track_v1' AND id != 'downstream_clip'")
db:exec("UPDATE clips SET timeline_start_frame = 200 WHERE id = 'downstream_clip'")

-- Clear marks — no marks = use full clip range
set_masterclip_marks(nested_sequence_id, nil, nil)
local insert_cmd3, "project")
insert_cmd3:set_parameter("nested_sequence_id", nested_sequence_id)
insert_cmd3:set_parameter("target_video_track_id", "track_v1")
insert_cmd3:set_parameter("sequence_id", "sequence")
insert_cmd3:set_parameter("timeline_start_frame", 0)
-- No marks set — should use full media duration (100 frames)edia duration (100 frames)

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
db:exec("DELETE FROM clips WHERE track_id = 'track_v1' AND id != 'downstream_clip'")
db:exec("UPDATE clips SET timeline_start_frame = 200 WHERE id = 'downstream_clip'")

set_masterclip_marks(nested_sequence_id, 0, 50)
loca, "project")
insert_cmd4:set_parameter("nested_sequence_id", nested_sequence_id)
insert_cmd4:set_parameter("target_video_track_id", "track_v1")
insert_cmd4:set_parameter("sequence_id", "sequence")
insert_cmd4:set_parameter("timeline_start_frame", 200)  -- Exactly at downstream start", 200)  -- Exactly at downstream start

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
asserts._set_enabled_for_, "project")
bad_cmd:set_parameter("target_video_track_id", "track_v1")
bad_cmd:set_parameter("sequence_id", "sequence")
bad_cmd:set_parameter("timeline_start_frame", 0)
-- No media_idbad_cmd:set_parameter("duration", 50)
-- No media_id

result = execute_cmd(bad_cmd)
asserts._set_enabled_for_tests(true)
assert(not result.success, "Insert without media_id should fail")

-- =============================================================================
-- TEST 8: Error case - nonexistent nested_sequence_id
-- =============================================================================
print("Test 8: Nonexistent nested_sequence_id fails")
asserts._set_, "project")
bad_cmd2:set_parameter("nested_sequence_id", nested_sequence_id)
bad_cmd2:set_parameter("target_video_track_id", "track_v1")
bad_cmd2:set_parameter("sequence_id", "sequence")
bad_cmd2:set_parameter("timeline_start_frame", 0)
bad_cmd2:set_parameter("nested_sequence_id", "nonexistent_master")  -- Should fail

result = execute_cmd(bad_cmd2)
asserts._set_enabled_for_tests(true)
assert(not result.success, "Insert with nonexistent nested_sequence_id should fail")

-- =============================================================================
-- TEST 9: Multiple undo/redo cycle maintains integrity
-- =============================================================================
print("Test 9: Multiple undo/redo cycle")
-- Reset state
db:exec("DELETE FROM clips WHERE track_id = 'track_v1' AND id != 'downstream_clip'")
db:exec("UPDATE clips SET timeline_start_frame = 200 WHERE id = 'downstream_clip'")

-- Insert 3 clips
set_masterclip_marks(nest, "project")
    cmd:set_parameter("nested_sequence_id", nested_sequence_id)
    cmd:set_parameter("target_video_track_id", "track_v1")
    cmd:set_parameter("sequence_id", "sequence")
    cmd:set_parameter("timeline_start_frame", 0)
    result = execute_cmd(cmd)
    assert(result.success, string.format("Insert %d should succeed", i))
end)
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
