#!/usr/bin/env luajit

-- Test: SetMark routes to focused monitor's sequence, not active_sequence_id
-- Regression: pressing I with source_monitor focused set mark on timeline instead

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Sequence = require('models.sequence')

local TEST_DB = "/tmp/jve/test_mark_routing.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()

-- Create project, timeline sequence, and masterclip sequence
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj', 'Test Project', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_rate, width, height, created_at, modified_at)
    VALUES ('timeline_seq', 'proj', 'Timeline', 'timeline', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_rate, width, height, created_at, modified_at)
    VALUES ('masterclip_seq', 'proj', 'Source Clip', 'masterclip', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'timeline_seq', 'V1', 'VIDEO', 1, 1);
]])

-- Verify sequences exist
local tl = Sequence.load("timeline_seq")
assert(tl, "timeline_seq must exist in DB")
local mc = Sequence.load("masterclip_seq")
assert(mc, "masterclip_seq must exist in DB")

-- Init command_manager with timeline sequence (this is what happens at project open)
command_manager.init("timeline_seq", "proj")
command_manager.activate_timeline_stack("timeline_seq")

-- Drain any stale command events left by init
while pcall(command_manager.end_command_event) do end

-- Mock panel_manager to simulate source_monitor focus
local mock_source_monitor = {
    sequence_id = "masterclip_seq",
    engine = {
        get_position = function() return 42 end,
    },
}

local mock_timeline_monitor = {
    sequence_id = "timeline_seq",
    engine = {
        get_position = function() return 10 end,
    },
}

local active_mock = mock_source_monitor
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function()
        return active_mock
    end,
}

--------------------------------------------------------------------------------
-- Test 1: SetMark with source_monitor focused should target masterclip_seq
-- (Current bug: it targets timeline_seq instead because execute_ui fills
--  sequence_id from active_sequence_id, ignoring focused monitor)
--------------------------------------------------------------------------------
print("=== Test 1: SetMark routes to active monitor's sequence ===")

local result = command_manager.execute_ui("SetMark", {
    _positional = {"in"},
})
assert(type(result) == "table" and result.success,
    "SetMark should succeed: " .. tostring(type(result) == "table" and result.error_message or result))

-- Load both sequences and check marks
local masterclip = Sequence.load("masterclip_seq")
local timeline = Sequence.load("timeline_seq")

-- This is the key assertion: mark should be on the FOCUSED sequence (masterclip),
-- not the TIMELINE sequence
assert(masterclip.mark_in == 42,
    string.format("ROUTING BUG: Expected masterclip mark_in=42 (focused monitor), got %s", tostring(masterclip.mark_in)))
assert(timeline.mark_in == nil,
    string.format("ROUTING BUG: Timeline mark_in should be nil (not focused), got %s", tostring(timeline.mark_in)))

print("  PASS: mark_in on masterclip_seq (focused): " .. tostring(masterclip.mark_in))
print("  PASS: mark_in on timeline_seq (unfocused): " .. tostring(timeline.mark_in))

--------------------------------------------------------------------------------
-- Test 2: SetMark with timeline_monitor focused should target timeline_seq
--------------------------------------------------------------------------------
print("=== Test 2: SetMark routes to timeline when timeline focused ===")

-- Switch mock to timeline_monitor
active_mock = mock_timeline_monitor

command_manager.undo()

local result2 = command_manager.execute_ui("SetMark", {
    _positional = {"in"},
})
assert(type(result2) == "table" and result2.success,
    "SetMark should succeed: " .. tostring(type(result2) == "table" and result2.error_message or result2))

local masterclip2 = Sequence.load("masterclip_seq")
local timeline2 = Sequence.load("timeline_seq")

assert(timeline2.mark_in == 10,
    string.format("Expected timeline mark_in=10, got %s", tostring(timeline2.mark_in)))
assert(masterclip2.mark_in == nil,
    string.format("Expected masterclip mark_in=nil after undo, got %s", tostring(masterclip2.mark_in)))

print("  PASS: mark_in on timeline_seq (focused): " .. tostring(timeline2.mark_in))
print("  PASS: mark_in on masterclip_seq (unfocused): " .. tostring(masterclip2.mark_in))

--------------------------------------------------------------------------------
-- Test 3: Explicit sequence_id overrides monitor routing
--------------------------------------------------------------------------------
print("=== Test 3: Explicit sequence_id overrides monitor ===")

-- Timeline monitor is active but we explicitly target masterclip
local result3 = command_manager.execute_ui("SetMark", {
    _positional = {"out"},
    sequence_id = "masterclip_seq",
    frame = 99,
})
assert(type(result3) == "table" and result3.success,
    "SetMark with explicit sequence_id should succeed: " .. tostring(type(result3) == "table" and result3.error_message or result3))

local masterclip3 = Sequence.load("masterclip_seq")
assert(masterclip3.mark_out == 100,  -- stored as exclusive: 99+1
    string.format("Expected masterclip mark_out=100 (exclusive), got %s", tostring(masterclip3.mark_out)))

print("  PASS: explicit sequence_id honored: masterclip mark_out=" .. tostring(masterclip3.mark_out))

print("✅ test_mark_routing.lua passed")
