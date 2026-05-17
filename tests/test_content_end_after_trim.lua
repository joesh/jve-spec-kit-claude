#!/usr/bin/env luajit

-- Regression: content end must update after trim shortens the last clip.
-- Bug: playback runs past trimmed clip end because cached total_frames
-- is never re-pushed to C++ PlaybackController after content_changed.
-- This test verifies the model layer: Sequence:compute_content_end()
-- returns the correct (shorter) value after TrimTail.

local test_env = require("test_env")

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Sequence = require('models.sequence')
local Command = require('command')
local command_manager = require('core.command_manager')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Content End After Trim ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_content_end_after_trim.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Disable overlap triggers
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

-- Create project/sequence at 25fps (non-trivial fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('proj1', 'Test', 'resample', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                          audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'sequence', 25, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('vt1', 'seq1', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('seq1', 'proj1')

local function execute_cmd(cmd)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(cmd)
    command_manager.end_command_event()
    return result
end

local function undo()
    command_manager.begin_command_event("script")
    command_manager.undo()
    command_manager.end_command_event()
end

-- Create media (500 frames @ 25fps)
local media = Media.create({
    id = "media1",
    project_id = "proj1",
    file_path = "/tmp/jve/fake.mov",
    name = "fake.mov",
    duration_frames = 500,
    fps_numerator = 25,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
})
assert(media:save(), "failed to save media")

-- Create masterclip sequence (500 frames @ 25fps)
local mc_id = test_env.create_test_masterclip_sequence(
    "proj1", "FakeMaster", 25, 1, 500, "media1")

-- Set marks on masterclip: source_in=25, source_out=125 (100 frames, non-trivial offset)
local mc_seq = assert(Sequence.load(mc_id), "masterclip not found")
mc_seq.mark_in = 25
mc_seq.mark_out = 125
assert(mc_seq:save(), "failed to save masterclip marks")

-- Insert clip at timeline position 50
local insert_cmd = Command.create("Insert", "proj1")
insert_cmd:set_parameter("source_sequence_id", mc_id)
insert_cmd:set_parameter("target_video_track_id", "vt1")
insert_cmd:set_parameter("sequence_id", "seq1")
insert_cmd:set_parameter("sequence_start_frame", 50)
local result = execute_cmd(insert_cmd)
assert(result.success, "Insert failed: " .. tostring(result.error_message))

-- Verify initial content end: 100 frames inserted at position 50 → clip at [50, 150)
local seq = Sequence.load("seq1")
assert(seq, "Sequence.load failed")
local initial_end = seq:compute_content_end()
print(string.format("After insert: content_end = %d (expected 150)", initial_end))
assert(initial_end == 150,
    string.format("Expected content_end=150 after insert, got %d", initial_end))

-- Find the clip we just inserted
local stmt = db:prepare("SELECT id FROM clips WHERE track_id = ?")
stmt:bind_value(1, "vt1")
stmt:exec()
assert(stmt:next(), "No clip found on track vt1")
local clip_id = stmt:value(0)
stmt:finalize()
assert(clip_id and clip_id ~= "", "clip_id is empty")

-- TrimTail at frame 100 → clip becomes [50, 100), content_end should be 100.
-- TrimTail accepts a clip_ids array + trim_frame (the playhead/cut frame).
local trim_cmd = Command.create("TrimTail", "proj1")
trim_cmd:set_parameter("project_id", "proj1")
trim_cmd:set_parameter("sequence_id", "seq1")
trim_cmd:set_parameter("clip_ids", { clip_id })
trim_cmd:set_parameter("trim_frame", 100)
local trim_result = execute_cmd(trim_cmd)
assert(trim_result.success, "TrimTail failed: " .. tostring(trim_result.error_message))

-- THE KEY ASSERTION: content end must reflect the trim
local trimmed_end = seq:compute_content_end()
print(string.format("After trim: content_end = %d (expected 100)", trimmed_end))
assert(trimmed_end == 100,
    string.format("BUG: content_end=%d after trim, expected 100", trimmed_end))

-- Verify clip state in DB
local trimmed_clip = Clip.load(clip_id)
assert(trimmed_clip, "clip disappeared after trim")
assert(trimmed_clip.duration == 50,
    string.format("Expected duration=50 after trim, got %d", trimmed_clip.duration))
assert(trimmed_clip.sequence_start == 50,
    string.format("Expected sequence_start=50, got %d", trimmed_clip.sequence_start))

-- Undo should restore content_end to 150
undo()
local undo_end = seq:compute_content_end()
print(string.format("After undo: content_end = %d (expected 150)", undo_end))
assert(undo_end == 150,
    string.format("BUG: content_end=%d after undo, expected 150", undo_end))

print("\n✅ test_content_end_after_trim.lua passed")
