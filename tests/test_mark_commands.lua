#!/usr/bin/env luajit

-- Test undoable mark commands: SetMarkIn, SetMarkOut, ClearMarkIn, ClearMarkOut,
-- ClearMarks, GetMarkIn, GetMarkOut.
-- Verifies undo/redo, signal emission, works on any sequence kind.

require('test_env')

local database = require('core.database')
local Sequence = require('models.sequence')
local command_manager = require('core.command_manager')
local Signals = require('core.signals')

print("=== test_mark_commands.lua ===")

-- Setup DB
local db_path = "/tmp/jve/test_mark_commands.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test', %d, %d);
]], now, now))

-- Create a TIMELINE sequence (not masterclip) to prove marks work on any kind
local seq = Sequence.create("Test Timeline", "project",
    {fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    {id = "seq_1", audio_rate = 48000})
assert(seq:save(), "setup: failed to save sequence")

command_manager.init('seq_1', 'project')

-- Helpers
local P = "project"
local S = "seq_1"

local function execute_cmd(name, params)
    params = params or {}
    params.project_id = params.project_id or P
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
    return result
end

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

local function reload_seq()
    return Sequence.load("seq_1")
end

-- Track marks_changed signal emissions
local signal_emissions = {}
Signals.connect("marks_changed", function(sequence_id)
    signal_emissions[#signal_emissions + 1] = sequence_id
end)

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
-- SetMarkIn
--------------------------------------------------------------------------------
print("\n--- SetMarkIn ---")

local r = execute_cmd("SetMarkIn", {sequence_id = S, frame = 48})
check("SetMarkIn succeeds", r.success, tostring(r.error_message))

local s = reload_seq()
check("SetMarkIn persisted", s.mark_in == 48, "expected 48, got " .. tostring(s.mark_in))
check("mark_out still nil", s.mark_out == nil)

-- Signal emitted
check("marks_changed signal emitted", #signal_emissions == 1 and signal_emissions[1] == S)

-- Undo
r = undo()
check("SetMarkIn undo succeeds", r.success, tostring(r.error_message))
s = reload_seq()
check("SetMarkIn undo restores nil", s.mark_in == nil, "expected nil, got " .. tostring(s.mark_in))
check("marks_changed on undo", #signal_emissions == 2)

-- Redo
r = redo()
check("SetMarkIn redo succeeds", r.success, tostring(r.error_message))
s = reload_seq()
check("SetMarkIn redo restores 48", s.mark_in == 48, "expected 48, got " .. tostring(s.mark_in))

--------------------------------------------------------------------------------
-- SetMarkOut
--------------------------------------------------------------------------------
print("\n--- SetMarkOut ---")

signal_emissions = {}
r = execute_cmd("SetMarkOut", {sequence_id = S, frame = 96})
check("SetMarkOut succeeds", r.success)
s = reload_seq()
check("SetMarkOut persisted", s.mark_out == 96, "expected 96, got " .. tostring(s.mark_out))
check("mark_in preserved", s.mark_in == 48, "expected 48, got " .. tostring(s.mark_in))
check("marks_changed signal emitted", #signal_emissions == 1)

-- Undo
r = undo()
check("SetMarkOut undo succeeds", r.success)
s = reload_seq()
check("SetMarkOut undo restores nil", s.mark_out == nil, "expected nil, got " .. tostring(s.mark_out))
check("mark_in still 48 after undo", s.mark_in == 48)

-- Redo
r = redo()
check("SetMarkOut redo succeeds", r.success)
s = reload_seq()
check("SetMarkOut redo restores 96", s.mark_out == 96)

--------------------------------------------------------------------------------
-- SetMarkIn overwrites existing
--------------------------------------------------------------------------------
print("\n--- SetMarkIn overwrites ---")

signal_emissions = {}
r = execute_cmd("SetMarkIn", {sequence_id = S, frame = 10})
check("SetMarkIn overwrite succeeds", r.success)
s = reload_seq()
check("mark_in now 10", s.mark_in == 10, "expected 10, got " .. tostring(s.mark_in))
check("mark_out still 96", s.mark_out == 96)

-- Undo restores PREVIOUS mark_in (48), not nil
undo()
s = reload_seq()
check("undo restores previous mark_in 48", s.mark_in == 48, "expected 48, got " .. tostring(s.mark_in))

-- Redo
redo()
s = reload_seq()
check("redo restores 10", s.mark_in == 10)

--------------------------------------------------------------------------------
-- ClearMarkIn
--------------------------------------------------------------------------------
print("\n--- ClearMarkIn ---")

signal_emissions = {}
r = execute_cmd("ClearMarkIn", {sequence_id = S})
check("ClearMarkIn succeeds", r.success, tostring(r.error_message))
s = reload_seq()
check("mark_in cleared", s.mark_in == nil, "expected nil, got " .. tostring(s.mark_in))
check("mark_out preserved", s.mark_out == 96)
check("marks_changed signal emitted", #signal_emissions >= 1)

-- Undo
undo()
s = reload_seq()
check("ClearMarkIn undo restores 10", s.mark_in == 10, "expected 10, got " .. tostring(s.mark_in))
check("mark_out still 96", s.mark_out == 96)

-- Redo
redo()
s = reload_seq()
check("ClearMarkIn redo clears again", s.mark_in == nil)

-- Undo again to restore for next test
undo()

--------------------------------------------------------------------------------
-- ClearMarkOut
--------------------------------------------------------------------------------
print("\n--- ClearMarkOut ---")

signal_emissions = {}
r = execute_cmd("ClearMarkOut", {sequence_id = S})
check("ClearMarkOut succeeds", r.success, tostring(r.error_message))
s = reload_seq()
check("mark_out cleared", s.mark_out == nil, "expected nil, got " .. tostring(s.mark_out))
check("mark_in preserved", s.mark_in == 10)

-- Undo
undo()
s = reload_seq()
check("ClearMarkOut undo restores 96", s.mark_out == 96, "expected 96, got " .. tostring(s.mark_out))

-- Redo
redo()
s = reload_seq()
check("ClearMarkOut redo clears again", s.mark_out == nil)

-- Undo again to restore for next test
undo()

--------------------------------------------------------------------------------
-- ClearMarks (both)
--------------------------------------------------------------------------------
print("\n--- ClearMarks ---")

-- State: mark_in=10, mark_out=96
s = reload_seq()
check("pre-ClearMarks: mark_in=10", s.mark_in == 10)
check("pre-ClearMarks: mark_out=96", s.mark_out == 96)

signal_emissions = {}
r = execute_cmd("ClearMarks", {sequence_id = S})
check("ClearMarks succeeds", r.success, tostring(r.error_message))
s = reload_seq()
check("both marks cleared", s.mark_in == nil and s.mark_out == nil)
check("marks_changed signal emitted", #signal_emissions >= 1)

-- Undo restores BOTH
undo()
s = reload_seq()
check("ClearMarks undo restores mark_in", s.mark_in == 10, "expected 10, got " .. tostring(s.mark_in))
check("ClearMarks undo restores mark_out", s.mark_out == 96, "expected 96, got " .. tostring(s.mark_out))

-- Redo
redo()
s = reload_seq()
check("ClearMarks redo clears both again", s.mark_in == nil and s.mark_out == nil)

--------------------------------------------------------------------------------
-- GetMarkIn / GetMarkOut (query, non-undoable)
--------------------------------------------------------------------------------
print("\n--- GetMarkIn / GetMarkOut ---")

-- Set marks first
execute_cmd("SetMarkIn", {sequence_id = S, frame = 24})
execute_cmd("SetMarkOut", {sequence_id = S, frame = 72})

r = execute_cmd("GetMarkIn", {sequence_id = S})
check("GetMarkIn succeeds", r.success)
local rd = r.result_data
check("GetMarkIn returns frame", type(rd) == "table" and rd.mark_in == 24,
    "expected 24, got " .. tostring(rd and rd.mark_in))

r = execute_cmd("GetMarkOut", {sequence_id = S})
check("GetMarkOut succeeds", r.success)
rd = r.result_data
check("GetMarkOut returns frame", type(rd) == "table" and rd.mark_out == 72,
    "expected 72, got " .. tostring(rd and rd.mark_out))

-- Query with no marks
execute_cmd("ClearMarks", {sequence_id = S})
r = execute_cmd("GetMarkIn", {sequence_id = S})
rd = r.result_data
check("GetMarkIn nil when cleared", r.success and type(rd) == "table" and rd.mark_in == nil)
r = execute_cmd("GetMarkOut", {sequence_id = S})
rd = r.result_data
check("GetMarkOut nil when cleared", r.success and type(rd) == "table" and rd.mark_out == nil)

--------------------------------------------------------------------------------
-- Error: missing sequence_id
--------------------------------------------------------------------------------
print("\n--- Error paths ---")

local ok, err = pcall(execute_cmd, "SetMarkIn", {frame = 10})
check("SetMarkIn missing seq_id errors", not ok, tostring(err))

ok, err = pcall(execute_cmd, "SetMarkOut", {frame = 10})
check("SetMarkOut missing seq_id errors", not ok, tostring(err))

--------------------------------------------------------------------------------
-- SetPlayhead emits playhead_changed signal
--------------------------------------------------------------------------------
print("\n--- SetPlayhead signal ---")

local ph_emissions = {}
local ph_conn = Signals.connect("playhead_changed", function(seq_id, frame)
    ph_emissions[#ph_emissions + 1] = {seq_id = seq_id, frame = frame}
end)

r = execute_cmd("SetPlayhead", {sequence_id = S, playhead_position = 42})
check("SetPlayhead succeeds", r.success, tostring(r.error_message))

-- Verify signal emitted with correct args
check("playhead_changed emitted", #ph_emissions == 1,
    "expected 1 emission, got " .. #ph_emissions)
check("playhead_changed seq_id", ph_emissions[1] and ph_emissions[1].seq_id == S)
check("playhead_changed frame", ph_emissions[1] and ph_emissions[1].frame == 42)

-- Verify persisted
s = reload_seq()
check("playhead persisted", s.playhead_position == 42,
    "expected 42, got " .. tostring(s.playhead_position))

Signals.disconnect(ph_conn)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_mark_commands.lua passed")
