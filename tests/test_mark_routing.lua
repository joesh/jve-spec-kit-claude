#!/usr/bin/env luajit

-- Test: SetMark routes to focused side's sequence, not active_sequence_id.
-- Regression: pressing I with source side focused set mark on timeline.
-- 017: routing is derived from focus_manager + timeline_state via the
-- transport target, so the test stubs those surfaces and a transport
-- with engines loaded to specific sequences.

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

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Test Project', 'resample', %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('timeline_seq', 'proj', 'Timeline', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                           audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('masterclip_seq', 'proj', 'Source Clip', 'master', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now))

db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'timeline_seq', 'V1', 'VIDEO', 1, 1);
]])

local tl = Sequence.load("timeline_seq")
assert(tl, "timeline_seq must exist in DB")
local mc = Sequence.load("masterclip_seq")
assert(mc, "masterclip_seq must exist in DB")

command_manager.init("timeline_seq", "proj")
command_manager.activate_timeline_stack("timeline_seq")
while pcall(command_manager.end_command_event) do end

-- Stub transport: two engines loaded to the two sequences with distinct
-- positions. The injection layer reads transport.engine_for_target().
local src_engine = {
    role = "source",
    loaded_sequence_id = "masterclip_seq",
    get_position = function() return 42 end,
}
local rec_engine = {
    role = "record",
    loaded_sequence_id = "timeline_seq",
    get_position = function() return 10 end,
}
package.loaded["core.playback.transport"] = {
    _project_id = "proj",
    is_bootstrapped = function() return true end,
    bound_project_id = function() return "proj" end,
    source_engine = src_engine,
    record_engine = rec_engine,
    engine_for_role = function(role)
        return role == "source" and src_engine or rec_engine
    end,
    engine_for_target = function() return src_engine end,
    seek_target_if_loaded = function() end,
    play_frame_audio_target_if_loaded = function() end,
    bind_role_to_sequence = function() end,
}
-- target_source: focus says source_monitor
package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "source_monitor" end,
}

--------------------------------------------------------------------------------
-- Test 1: SetMark with source side focused → masterclip_seq
--------------------------------------------------------------------------------
print("=== Test 1: SetMark routes to source side (focused) ===")

local result = command_manager.execute_interactive("SetMark", {_positional = {"in"}})
assert(type(result) == "table" and result.success,
    "SetMark should succeed: " ..
    tostring(type(result) == "table" and result.error_message or result))

local masterclip = Sequence.load("masterclip_seq")
local timeline = Sequence.load("timeline_seq")

assert(masterclip.mark_in == 42,
    string.format("ROUTING BUG: Expected masterclip mark_in=42, got %s",
        tostring(masterclip.mark_in)))
assert(timeline.mark_in == nil,
    string.format("ROUTING BUG: Timeline mark_in should be nil, got %s",
        tostring(timeline.mark_in)))

print("  PASS: mark_in on masterclip_seq (focused): " .. tostring(masterclip.mark_in))
print("  PASS: mark_in on timeline_seq (unfocused): " .. tostring(timeline.mark_in))

--------------------------------------------------------------------------------
-- Test 2: SetMark with record side displayed → timeline_seq
--------------------------------------------------------------------------------
print("=== Test 2: SetMark routes to record when record is the displayed tab ===")

-- Flip the focus + transport target to record.
package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "timeline" end,
}
package.loaded["core.playback.transport"].engine_for_target =
    function() return rec_engine end

command_manager.undo()

local result2 = command_manager.execute_interactive("SetMark", {_positional = {"in"}})
assert(type(result2) == "table" and result2.success,
    "SetMark should succeed: " ..
    tostring(type(result2) == "table" and result2.error_message or result2))

local masterclip2 = Sequence.load("masterclip_seq")
local timeline2 = Sequence.load("timeline_seq")

assert(timeline2.mark_in == 10,
    string.format("Expected timeline mark_in=10, got %s", tostring(timeline2.mark_in)))
assert(masterclip2.mark_in == nil,
    string.format("Expected masterclip mark_in=nil after undo, got %s",
        tostring(masterclip2.mark_in)))

print("  PASS: mark_in on timeline_seq (focused): " .. tostring(timeline2.mark_in))
print("  PASS: mark_in on masterclip_seq (restored by undo): " .. tostring(masterclip2.mark_in))

print("\n✅ test_mark_routing.lua passed")
