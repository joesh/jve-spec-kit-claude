#!/usr/bin/env luajit

-- T005: Sequence generation counter.
--
-- Domain behavior: each mutation on a sequence increments its generation
-- counter. This enables O(1) staleness detection for nested sequence
-- references.

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")

local db_path = "/tmp/jve/test_sequence_generation.db"
os.remove(db_path)
local db = database.open(db_path)
database.init_schema(db)

-- Create project + sequence
db:exec("INSERT INTO projects (id, name) VALUES ('proj1', 'test')")
db:exec("INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator) VALUES ('seq1', 'proj1', 'Seq 1', 25, 1)")

-- Load and check initial generation
local seq = Sequence.load("seq1")
assert(seq, "sequence must exist")
assert(seq.mutation_generation == 0,
    "initial mutation_generation should be 0, got " .. tostring(seq.mutation_generation))

-- Increment and verify
Sequence.increment_generation("seq1")
seq = Sequence.load("seq1")
assert(seq.mutation_generation == 1,
    "mutation_generation should be 1 after first increment, got " .. tostring(seq.mutation_generation))

-- Increment again
Sequence.increment_generation("seq1")
seq = Sequence.load("seq1")
assert(seq.mutation_generation == 2,
    "mutation_generation should be 2 after second increment, got " .. tostring(seq.mutation_generation))

db:close()
os.remove(db_path)

print("✅ test_sequence_generation.lua passed")
