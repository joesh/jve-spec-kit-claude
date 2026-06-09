#!/usr/bin/env luajit

-- Sequence mutation generation counter regression guard (feature 008).
--
-- Domain behavior: each sequence carries a monotonically increasing
-- mutation_generation counter. Every successful sequence-scoped
-- mutation must increment it — including undo and redo, since a
-- rollback is itself a state transition that invalidates any cached
-- reference to a prior generation. O(1) staleness detection for
-- nested-sequence references lives on this counter: a compound clip
-- referencing sub-sequence X caches X's generation at reference time
-- and compares against the current value on read.

local test_env = require("test_env")

-- Stub out the Qt shim used by panel manager wiring so command_manager
-- can run without a real UI loop.
_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require("core.database")
local Sequence = require("models.sequence")

local db_path = "/tmp/jve/test_sequence_generation.db"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
database.init(db_path)
local db = database.get_connection()

-- Seed a project + sequence with all NOT NULL columns populated.
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height,
        created_at, modified_at
    ) VALUES ('seq1', 'proj1', 'Seq 1', 'sequence',
              25, 1, 48000,
              1920, 1080,
              %d, %d);
]], now, now))

-- Initial generation is 0.
local seq = Sequence.load("seq1")
assert(seq, "sequence must exist after insert")
assert(seq.mutation_generation == 0,
    "initial mutation_generation should be 0, got " .. tostring(seq.mutation_generation))

-- First increment → 1.
Sequence.increment_generation("seq1")
seq = Sequence.load("seq1")
assert(seq.mutation_generation == 1,
    "mutation_generation should be 1 after first increment, got " .. tostring(seq.mutation_generation))

-- Second increment → 2. Counter is monotonic, never resets.
Sequence.increment_generation("seq1")
seq = Sequence.load("seq1")
assert(seq.mutation_generation == 2,
    "mutation_generation should be 2 after second increment, got " .. tostring(seq.mutation_generation))

-- Increment must assert on empty id.
local ok, err = pcall(Sequence.increment_generation, "")
assert(not ok and err and err:find("sequence_id is required"),
    "increment_generation should reject empty sequence_id with a clear error")

-- Increment must assert when the sequence_id names a row that does not
-- exist. Silently running UPDATE ... WHERE id = '<bogus>' with zero rows
-- affected would hide a caller bug (stale sequence_id on a command).
local ok_missing, err_missing = pcall(Sequence.increment_generation, "no_such_seq")
assert(not ok_missing and err_missing and err_missing:find("no row") ~= nil,
    "increment_generation should assert on nonexistent sequence_id, got: " .. tostring(err_missing))

-- ----------------------------------------------------------------------
-- Integration: execute → undo → redo must each bump the counter.
-- ----------------------------------------------------------------------
-- Seed the minimum schema needed to run a real Insert command through
-- command_manager: add a track + a masterclip + a media file. The
-- Insert command is the simplest sequence-scoped mutation available
-- and exercises both execute and undo/redo paths.

local Command = require("command")
local Media = require("models.media")
local command_manager = require("core.command_manager")

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
                        enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

local media = assert(Media.create({
    id = "m1", project_id = "proj1",
    file_path = "/tmp/jve/test_sequence_generation.mov", name = "m1.mov",
    duration_frames = 500,
    fps_numerator = 25, fps_denominator = 1,
    width = 1920, height = 1080,
}), "Media.create returned nil")
assert(media:save(db), "media:save returned false")

local mc_id = test_env.create_test_masterclip_sequence('proj1', 'MC1', 25, 1, 500, "m1")

command_manager.init('seq1', 'proj1')

-- Reset counter to a known baseline after the direct-call exercises
-- above so assertions below read cleanly as "before vs after command".
db:exec("UPDATE sequences SET mutation_generation = 0 WHERE id = 'seq1'")

local function current_generation()
    return Sequence.load("seq1").mutation_generation
end

local function expect_generation(expected, label)
    local actual = current_generation()
    assert(actual == expected,
        string.format("%s: expected generation %d, got %s",
            label, expected, tostring(actual)))
end

expect_generation(0, "baseline before Insert")

local insert_cmd = Command.create("Insert", "proj1")
insert_cmd:set_parameter("sequence_id", "seq1")
insert_cmd:set_parameter("target_video_track_id", "v1")
insert_cmd:set_parameter("source_sequence_id", mc_id)
insert_cmd:set_parameter("clip_name", "clip_a")
insert_cmd:set_parameter("sequence_start_frame", 100)

local r = command_manager.execute(insert_cmd)
assert(r and r.success, "Insert failed: " .. tostring(r and r.error_message))
expect_generation(1, "after execute")

local u = command_manager.undo()
assert(u and u.success, "undo failed: " .. tostring(u and u.error_message))
expect_generation(2, "after undo")

local rd = command_manager.redo()
assert(rd and rd.success, "redo failed: " .. tostring(rd and rd.error_message))
expect_generation(3, "after redo")

database.shutdown()
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")

print("✅ test_sequence_generation.lua passed")
