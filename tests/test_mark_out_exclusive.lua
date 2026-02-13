#!/usr/bin/env luajit

-- Test: SetMarkOut stores exclusive boundary (frame + 1).
-- GoToMarkOut navigates to last included frame (mark_out - 1).
-- Duration math: mark_out - mark_in = correct frame count.
--
-- NLE standard (Adobe/Resolve/Avid/FCP): user on frame 50 presses O,
-- mark_out stores 51 (exclusive). Go-to-Out lands on 50 (inclusive).

require('test_env')

local database = require('core.database')
local Sequence = require('models.sequence')
local command_manager = require('core.command_manager')

print("=== test_mark_out_exclusive.lua ===")

-- Setup DB
local db_path = "/tmp/jve/test_mark_out_exclusive.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test', %d, %d);
]], now, now))

local seq = Sequence.create("Test Timeline", "project",
    {fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    {id = "seq_1", audio_rate = 48000})
assert(seq:save(), "setup: failed to save sequence")
command_manager.init('seq_1', 'project')

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
-- SetMarkOut stores exclusive boundary (frame + 1)
--------------------------------------------------------------------------------
print("\n--- SetMarkOut stores exclusive ---")

-- User viewing frame 50, presses O → SetMarkOut(frame=50)
local r = execute_cmd("SetMarkOut", {sequence_id = S, frame = 50})
check("SetMarkOut succeeds", r.success, tostring(r.error_message))

local s = reload_seq()
check("SetMarkOut(50) stores 51 (exclusive)",
    s.mark_out == 51,
    "expected 51, got " .. tostring(s.mark_out))

-- Undo restores nil
undo()
s = reload_seq()
check("undo restores nil", s.mark_out == nil)

-- Redo restores exclusive value
redo()
s = reload_seq()
check("redo restores 51", s.mark_out == 51,
    "expected 51, got " .. tostring(s.mark_out))

--------------------------------------------------------------------------------
-- Duration math: mark_out - mark_in = inclusive frame count
--------------------------------------------------------------------------------
print("\n--- Duration = mark_out - mark_in ---")

-- Set in at frame 10, out at frame 50
-- Should include frames 10..50 = 41 frames
execute_cmd("SetMarkIn", {sequence_id = S, frame = 10})
execute_cmd("SetMarkOut", {sequence_id = S, frame = 50})

s = reload_seq()
local duration = s.mark_out - s.mark_in
check("duration = 41 (frames 10..50 inclusive)",
    duration == 41,
    "expected 41, got " .. tostring(duration))

--------------------------------------------------------------------------------
-- GoToMarkOut navigates to last included frame (mark_out - 1)
--------------------------------------------------------------------------------
print("\n--- GoToMarkOut ---")

-- mark_out = 51 (exclusive), GoToMarkOut should land on 50
r = execute_cmd("GoToMarkOut", {sequence_id = S})
check("GoToMarkOut succeeds", r.success, tostring(r.error_message))

s = reload_seq()
check("GoToMarkOut lands on 50 (last included frame)",
    s.playhead_position == 50,
    "expected 50, got " .. tostring(s.playhead_position))

--------------------------------------------------------------------------------
-- GoToMarkIn navigates to mark_in (already inclusive)
--------------------------------------------------------------------------------
print("\n--- GoToMarkIn ---")

r = execute_cmd("GoToMarkIn", {sequence_id = S})
check("GoToMarkIn succeeds", r.success, tostring(r.error_message))

s = reload_seq()
check("GoToMarkIn lands on 10",
    s.playhead_position == 10,
    "expected 10, got " .. tostring(s.playhead_position))

--------------------------------------------------------------------------------
-- GoToMarkOut with no mark set: no-op (no crash)
--------------------------------------------------------------------------------
print("\n--- GoTo with no marks ---")

execute_cmd("ClearMarks", {sequence_id = S})

-- Set playhead to known position
execute_cmd("SetPlayhead", {sequence_id = S, playhead_position = 42})

r = execute_cmd("GoToMarkOut", {sequence_id = S})
check("GoToMarkOut no-op when no mark", r.success)
s = reload_seq()
check("playhead unchanged", s.playhead_position == 42,
    "expected 42, got " .. tostring(s.playhead_position))

r = execute_cmd("GoToMarkIn", {sequence_id = S})
check("GoToMarkIn no-op when no mark", r.success)
s = reload_seq()
check("playhead unchanged", s.playhead_position == 42,
    "expected 42, got " .. tostring(s.playhead_position))

--------------------------------------------------------------------------------
-- SetMarkOut overwrites: undo restores previous exclusive value
--------------------------------------------------------------------------------
print("\n--- Overwrite + undo ---")

execute_cmd("SetMarkOut", {sequence_id = S, frame = 50})  -- stores 51
execute_cmd("SetMarkOut", {sequence_id = S, frame = 70})  -- stores 71

s = reload_seq()
check("overwrite stores 71", s.mark_out == 71,
    "expected 71, got " .. tostring(s.mark_out))

undo()
s = reload_seq()
check("undo restores previous exclusive (51)", s.mark_out == 51,
    "expected 51, got " .. tostring(s.mark_out))

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_mark_out_exclusive.lua passed")
