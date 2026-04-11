#!/usr/bin/env luajit

-- Sequence mutation generation counter regression guard (feature 008).
--
-- Domain behavior: each sequence carries a monotonically increasing
-- mutation_generation counter. Every successful sequence-scoped
-- mutation must increment it. O(1) staleness detection for
-- nested-sequence references lives on this counter: a compound clip
-- referencing sub-sequence X caches X's generation at reference time
-- and compares against the current value on read.

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")

local db_path = "/tmp/jve/test_sequence_generation.db"
os.remove(db_path)
database.init(db_path)
local db = database.get_connection()

-- Seed a project + sequence with all NOT NULL columns populated.
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'test', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        created_at, modified_at
    ) VALUES ('seq1', 'proj1', 'Seq 1', 'timeline',
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

database.shutdown()
os.remove(db_path)

print("✅ test_sequence_generation.lua passed")
