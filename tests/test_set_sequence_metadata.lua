#!/usr/bin/env luajit

-- Tests for SetSequenceMetadata command

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')

local TEST_DB = "/tmp/jve/test_set_sequence_metadata.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Metadata Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        created_at, modified_at)
    VALUES ('test_seq', 'test_project', 'Original Name', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, now, now))

-- Stub timeline_state
local timeline_state = {
    capture_viewport = function() return {start_value = 0, duration_value = 240} end,
    push_viewport_guard = function() end,
    pop_viewport_guard = function() end,
    restore_viewport = function(_) end,
    set_selection = function(_) end,
    get_selected_clips = function() return {} end,
    set_edge_selection = function(_) end,
    get_selected_edges = function() return {} end,
    set_playhead_position = function(_) end,
    get_playhead_position = function() return 0 end,
    reload_clips = function() end,
    get_sequence_frame_rate = function() return {fps_numerator = 30, fps_denominator = 1} end,
    get_sequence_id = function() return "test_seq" end,
}
package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init("test_seq", "test_project")

local function get_sequence_field(field)
    local stmt = db:prepare("SELECT " .. field .. " FROM sequences WHERE id = 'test_seq'")
    if stmt:exec() and stmt:next() then
        local val = stmt:value(0)
        stmt:finalize()
        return val
    end
    stmt:finalize()
    return nil
end

print("=== SetSequenceMetadata Command Tests ===")

-- Test 1: Set sequence name
print("Test 1: Set sequence name")
local set_name_cmd = Command.create("SetSequenceMetadata", "test_project")
set_name_cmd:set_parameter("project_id", "test_project")
set_name_cmd:set_parameter("sequence_id", "test_seq")
set_name_cmd:set_parameter("field", "name")
set_name_cmd:set_parameter("value", "New Sequence Name")

local result = command_manager.execute(set_name_cmd)
assert(result.success, "SetSequenceMetadata (name) failed: " .. tostring(result.error_message))
assert(get_sequence_field("name") == "New Sequence Name", "Name should be updated")

-- Test 2: Undo restores original name
print("Test 2: Undo restores original name")
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo failed: " .. tostring(undo_result.error_message))
assert(get_sequence_field("name") == "Original Name", "Name should be restored")

-- Test 3: Redo reapplies new name
print("Test 3: Redo reapplies new name")
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo failed: " .. tostring(redo_result.error_message))
assert(get_sequence_field("name") == "New Sequence Name", "Name should be set again")

-- Test 4: Set width (numeric field)
print("Test 4: Set width (numeric field)")
local set_width_cmd = Command.create("SetSequenceMetadata", "test_project")
set_width_cmd:set_parameter("project_id", "test_project")
set_width_cmd:set_parameter("sequence_id", "test_seq")
set_width_cmd:set_parameter("field", "width")
set_width_cmd:set_parameter("value", 3840)

result = command_manager.execute(set_width_cmd)
assert(result.success, "SetSequenceMetadata (width) failed: " .. tostring(result.error_message))
assert(get_sequence_field("width") == 3840, "Width should be 3840")

-- Test 5: Set height (numeric field)
print("Test 5: Set height (numeric field)")
local set_height_cmd = Command.create("SetSequenceMetadata", "test_project")
set_height_cmd:set_parameter("project_id", "test_project")
set_height_cmd:set_parameter("sequence_id", "test_seq")
set_height_cmd:set_parameter("field", "height")
set_height_cmd:set_parameter("value", 2160)

result = command_manager.execute(set_height_cmd)
assert(result.success, "SetSequenceMetadata (height) failed: " .. tostring(result.error_message))
assert(get_sequence_field("height") == 2160, "Height should be 2160")

-- Test 6: Invalid field fails
print("Test 6: Invalid field fails (expect error)")
local invalid_cmd = Command.create("SetSequenceMetadata", "test_project")
invalid_cmd:set_parameter("project_id", "test_project")
invalid_cmd:set_parameter("sequence_id", "test_seq")
invalid_cmd:set_parameter("field", "nonexistent_field")
invalid_cmd:set_parameter("value", "anything")

result = command_manager.execute(invalid_cmd)
assert(not result.success, "Invalid field should fail")

-- Test 7: Multiple undo/redo cycles maintain integrity
print("Test 7: Multiple undo/redo cycles maintain integrity")
-- Undo height
local u1 = command_manager.undo()
assert(u1.success, "Undo height failed")
assert(get_sequence_field("height") == 1080, "Height should be restored to 1080")

-- Undo width
local u2 = command_manager.undo()
assert(u2.success, "Undo width failed")
assert(get_sequence_field("width") == 1920, "Width should be restored to 1920")

-- Redo both
local r1 = command_manager.redo()
assert(r1.success, "Redo width failed")
assert(get_sequence_field("width") == 3840, "Width should be 3840 again")

local r2 = command_manager.redo()
assert(r2.success, "Redo height failed")
assert(get_sequence_field("height") == 2160, "Height should be 2160 again")

-- Test 8: Setting numeric field with string value normalizes it
print("Test 8: Numeric field with string value gets normalized")
local string_num_cmd = Command.create("SetSequenceMetadata", "test_project")
string_num_cmd:set_parameter("project_id", "test_project")
string_num_cmd:set_parameter("sequence_id", "test_seq")
string_num_cmd:set_parameter("field", "width")
string_num_cmd:set_parameter("value", "1280")  -- string, not number

result = command_manager.execute(string_num_cmd)
assert(result.success, "String numeric value failed: " .. tostring(result.error_message))
assert(get_sequence_field("width") == 1280, "Width should be normalized to 1280")

print("✅ test_set_sequence_metadata.lua passed")
