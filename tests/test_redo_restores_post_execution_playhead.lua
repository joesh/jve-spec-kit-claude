#!/usr/bin/env luajit

-- Regression test: Redo should restore the post-execution playhead position
-- from the captured value, NOT by re-running executor logic.
--
-- This test verifies that playhead_value_post is captured and restored on redo,
-- independent of the executor's advance_playhead behavior.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local Rational = require("core.rational")

local SCHEMA_SQL = require("import_schema")

local BASE_DATA_SQL = [[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES ('seq1', 'default_project', 'Sequence', 'timeline',
            30, 1, 48000, 1920, 1080, 0, 300, 0, '[]', '[]', '[]', 0,
            strftime('%s','now'), strftime('%s','now'));

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('media1', 'default_project', '/tmp/test.mov', 'Test Media', 3000, 30, 1, strftime('%s','now'), strftime('%s','now'));
]]

local function setup_database(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec(BASE_DATA_SQL))
    command_manager.init("seq1", "default_project")
    return db
end

-- Mock timeline_state to track playhead operations
local playhead_position = 0
local original_timeline_state = nil
local playhead_set_calls = {}  -- Track who sets playhead

local function setup_mock_timeline_state()
    original_timeline_state = package.loaded['ui.timeline.timeline_state']

    local mock = {
        get_playhead_position = function()
            return playhead_position
        end,
        set_playhead_position = function(pos)
            table.insert(playhead_set_calls, {pos = pos, source = debug.traceback()})
            playhead_position = pos
        end,
        get_sequence_frame_rate = function()
            return { fps_numerator = 30, fps_denominator = 1 }
        end,
        get_sequence_id = function()
            return "seq1"
        end,
        get_audio_tracks = function()
            return {}
        end,
        get_selected_clips = function()
            return {}
        end,
        get_selected_edges = function()
            return {}
        end,
        get_selected_gaps = function()
            return {}
        end,
        set_selection = function() end,
        set_gap_selection = function() end,
        apply_mutations = function() return true end,
        reload_clips = function() end,
    }

    package.loaded['ui.timeline.timeline_state'] = mock
    return mock
end

local function teardown_mock_timeline_state()
    if original_timeline_state then
        package.loaded['ui.timeline.timeline_state'] = original_timeline_state
    end
end

local db = setup_database("/tmp/jve/test_redo_playhead.db")
local mock_timeline = setup_mock_timeline_state()

-- Helper: execute command with proper event wrapping
local function execute_command(cmd)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(cmd)
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

local function get_frames(pos)
    return type(pos) == "table" and pos.frames or pos
end

print("=== Redo Playhead Position Regression Test ===")
print("This test verifies playhead_value_post is captured and restored on redo\n")

-- Initial state: playhead at frame 0
playhead_position = 0
playhead_set_calls = {}
print(string.format("Initial playhead position: %s", tostring(playhead_position)))

-- Execute Insert with advance_playhead=true
local insert_cmd = Command.create("Insert", "default_project")
insert_cmd:set_parameter("sequence_id", "seq1")
insert_cmd:set_parameter("track_id", "v1")
insert_cmd:set_parameter("media_id", "media1")
insert_cmd:set_parameter("insert_time", 0)
insert_cmd:set_parameter("duration", 100)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", 100)
insert_cmd:set_parameter("advance_playhead", true)

print("\nStep 1: Execute Insert command (100 frames at position 0)...")
local result = execute_command(insert_cmd)
assert(result.success, result.error_message or "Insert failed")

local post_execution_playhead = get_frames(playhead_position)
print(string.format("  Post-execution playhead: frame %d (expected: 100)", post_execution_playhead))
assert(post_execution_playhead == 100, string.format(
    "Expected playhead at frame 100 after insert, got %d", post_execution_playhead))

-- Verify playhead_value_post was captured in database
print("\nStep 2: Verify playhead_value_post was captured in database...")
local check_stmt = db:prepare("SELECT playhead_value_post FROM commands ORDER BY sequence_number DESC LIMIT 1")
assert(check_stmt and check_stmt:exec() and check_stmt:next(), "Failed to query commands table")
local captured_post_playhead = check_stmt:value(0)
check_stmt:finalize()

assert(captured_post_playhead ~= nil,
    "REGRESSION: playhead_value_post was NOT captured! This field must be populated after command execution.")
print(string.format("  Captured playhead_value_post: %s", tostring(captured_post_playhead)))
assert(captured_post_playhead == 100, string.format(
    "Expected captured playhead_value_post=100, got %s", tostring(captured_post_playhead)))

-- Undo
print("\nStep 3: Undo the Insert command...")
result = undo()
assert(result.success, result.error_message or "Undo failed")

local post_undo_playhead = get_frames(playhead_position)
print(string.format("  Post-undo playhead: frame %d (expected: 0)", post_undo_playhead))
assert(post_undo_playhead == 0, string.format(
    "Expected playhead at frame 0 after undo, got %d", post_undo_playhead))

-- Now the key test: Redo should restore from playhead_value_post
-- We verify this by checking that the LAST set_playhead_position call came from
-- execute_redo_command's restoration code, not from the executor's advance_playhead logic
print("\nStep 4: Redo the Insert command...")
playhead_set_calls = {}  -- Reset tracking
result = redo()
assert(result.success, result.error_message or "Redo failed")

local post_redo_playhead = get_frames(playhead_position)
print(string.format("  Post-redo playhead: frame %d (expected: 100)", post_redo_playhead))

-- The playhead should be at 100 regardless of how it got there
assert(post_redo_playhead == 100, string.format(
    "REGRESSION: Expected playhead at frame 100 after redo, got %d", post_redo_playhead))

-- Verify that playhead was set (at least once during redo)
assert(#playhead_set_calls > 0, "REGRESSION: No set_playhead_position calls during redo")

-- The LAST call should be from execute_redo_command restoring playhead_value_post
-- NOT from the executor (insert.lua/overwrite.lua) re-running advance_playhead logic
local last_call = playhead_set_calls[#playhead_set_calls]

-- Check that the last call does NOT come from insert.lua (the executor)
-- If it comes from insert.lua, redo is relying on executor logic, not captured value
local last_call_from_executor = last_call.source:find("insert%.lua") ~= nil or
                                 last_call.source:find("overwrite%.lua") ~= nil

print(string.format("  Number of set_playhead_position calls during redo: %d", #playhead_set_calls))
print(string.format("  Final playhead value set: %s", tostring(get_frames(last_call.pos))))

-- THIS IS THE KEY ASSERTION: The playhead should be restored from captured value,
-- not from the executor re-running advance_playhead logic
assert(not last_call_from_executor,
    "REGRESSION: The final set_playhead_position during redo came from the executor " ..
    "(insert.lua/overwrite.lua), not from execute_redo_command restoring playhead_value_post. " ..
    "This means redo is relying on re-running executor logic instead of restoring captured state.\n" ..
    "Last call stack:\n" .. last_call.source)

teardown_mock_timeline_state()

print("\n" .. string.rep("=", 80))
print("REGRESSION TEST PASSED")
print(string.rep("=", 80))
print("Verified:")
print("  1. playhead_value_post is captured after command execution")
print("  2. Redo restores playhead from captured value (not re-running executor logic)")
print(string.rep("=", 80))
