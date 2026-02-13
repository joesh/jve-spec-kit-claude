#!/usr/bin/env luajit

-- Test unified mark commands at module level (direct executor registration).
-- Verifies the set_marks.lua module registers all 7 commands correctly
-- and the executor/undoer pairs work in isolation.

require('test_env')

local database = require('core.database')
local Sequence = require('models.sequence')

print("=== test_source_marks.lua ===")

-- Setup DB
local db_path = "/tmp/jve/test_source_marks_unified.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test', %d, %d);
]], now, now))

-- Create a masterclip sequence to prove marks work on masterclips too
local seq = Sequence.create("Test MC", "project",
    {fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    {id = "mc_1", kind = "masterclip", audio_rate = 48000})
assert(seq:save(), "setup: failed to save sequence")

-- Load set_marks module and register executors directly
local set_marks = require('core.commands.set_marks')
local executors = {}
local undoers = {}
set_marks.register(executors, undoers)

-- Helper: build a minimal command object with parameters
local function make_command(params)
    local stored = {}
    for k, v in pairs(params or {}) do stored[k] = v end
    return {
        get_all_parameters = function() return stored end,
        set_parameter = function(_, k, v) stored[k] = v end,
    }
end

local pass_count = 0
local fail_count = 0

local function check(label, condition, msg)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label .. (msg and (" — " .. msg) or ""))
    end
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------
print("\n--- Registration ---")

check("SetMarkIn registered", type(executors["SetMarkIn"]) == "function")
check("SetMarkOut registered", type(executors["SetMarkOut"]) == "function")
check("ClearMarkIn registered", type(executors["ClearMarkIn"]) == "function")
check("ClearMarkOut registered", type(executors["ClearMarkOut"]) == "function")
check("ClearMarks registered", type(executors["ClearMarks"]) == "function")
check("GetMarkIn registered", type(executors["GetMarkIn"]) == "function")
check("GetMarkOut registered", type(executors["GetMarkOut"]) == "function")
check("SetMarkIn undoer registered", type(undoers["SetMarkIn"]) == "function")
check("SetMarkOut undoer registered", type(undoers["SetMarkOut"]) == "function")
check("ClearMarks undoer registered", type(undoers["ClearMarks"]) == "function")

--------------------------------------------------------------------------------
-- SetMarkIn on masterclip sequence
--------------------------------------------------------------------------------
print("\n--- SetMarkIn on masterclip ---")

local cmd = make_command({sequence_id = "mc_1", frame = 42})
local r = executors["SetMarkIn"](cmd)
check("SetMarkIn succeeds", r.success)

local s = Sequence.load("mc_1")
check("mark_in persisted to 42", s.mark_in == 42, "got " .. tostring(s.mark_in))

-- Undo via undoer
r = undoers["SetMarkIn"](cmd)
check("SetMarkIn undo succeeds", r.success)
s = Sequence.load("mc_1")
check("mark_in restored to nil", s.mark_in == nil, "got " .. tostring(s.mark_in))

--------------------------------------------------------------------------------
-- SetMarkOut
--------------------------------------------------------------------------------
print("\n--- SetMarkOut ---")

cmd = make_command({sequence_id = "mc_1", frame = 99})
r = executors["SetMarkOut"](cmd)
check("SetMarkOut succeeds", r.success)
s = Sequence.load("mc_1")
-- SetMarkOut stores exclusive: frame + 1 = 100
check("mark_out persisted to 100 (exclusive)", s.mark_out == 100)

-- Undo
undoers["SetMarkOut"](cmd)
s = Sequence.load("mc_1")
check("mark_out restored to nil", s.mark_out == nil)

--------------------------------------------------------------------------------
-- ClearMarks
--------------------------------------------------------------------------------
print("\n--- ClearMarks ---")

-- Set marks first
executors["SetMarkIn"](make_command({sequence_id = "mc_1", frame = 10}))
executors["SetMarkOut"](make_command({sequence_id = "mc_1", frame = 50}))

cmd = make_command({sequence_id = "mc_1"})
r = executors["ClearMarks"](cmd)
check("ClearMarks succeeds", r.success)
s = Sequence.load("mc_1")
check("both marks cleared", s.mark_in == nil and s.mark_out == nil)

-- Undo
undoers["ClearMarks"](cmd)
s = Sequence.load("mc_1")
check("ClearMarks undo restores mark_in", s.mark_in == 10, "got " .. tostring(s.mark_in))
-- SetMarkOut(50) stored 51 (exclusive)
check("ClearMarks undo restores mark_out", s.mark_out == 51, "got " .. tostring(s.mark_out))

--------------------------------------------------------------------------------
-- GetMarkIn / GetMarkOut
--------------------------------------------------------------------------------
print("\n--- GetMarkIn / GetMarkOut ---")

r = executors["GetMarkIn"](make_command({sequence_id = "mc_1"}))
check("GetMarkIn succeeds", r.success)
check("GetMarkIn returns 10", r.result_data and r.result_data.mark_in == 10)

r = executors["GetMarkOut"](make_command({sequence_id = "mc_1"}))
check("GetMarkOut succeeds", r.success)
-- GetMarkOut returns exclusive boundary (50 + 1 = 51)
check("GetMarkOut returns 51 (exclusive)", r.result_data and r.result_data.mark_out == 51)

--------------------------------------------------------------------------------
-- Error: missing sequence_id asserts
--------------------------------------------------------------------------------
print("\n--- Error paths ---")

local ok, err = pcall(executors["SetMarkIn"], make_command({frame = 10}))
check("SetMarkIn nil seq_id asserts", not ok, tostring(err))

ok, err = pcall(executors["SetMarkOut"], make_command({frame = 10}))
check("SetMarkOut nil seq_id asserts", not ok, tostring(err))

ok, err = pcall(executors["ClearMarks"], make_command({}))
check("ClearMarks nil seq_id asserts", not ok, tostring(err))

ok, err = pcall(executors["SetMarkIn"], make_command({sequence_id = "mc_1"}))
check("SetMarkIn nil frame asserts", not ok, tostring(err))

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_source_marks.lua passed")
