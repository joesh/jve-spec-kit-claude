#!/usr/bin/env luajit

-- Tests for SetProjectSetting command (non-undoable, scriptable)
require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local uuid = require('uuid')

local TEST_DB = "/tmp/jve/test_set_project_setting.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
local sequence_id = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Settings Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        created_at, modified_at)
    VALUES ('%s', 'test_project', 'Test Seq', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, sequence_id, now, now))

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
    get_sequence_id = function() return sequence_id end,
}
package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init(sequence_id, "test_project")

print("=== SetProjectSetting Command Tests ===")

-- Test 1: Set simple project setting
print("Test 1: Set simple project setting")
local cmd = Command.create("SetProjectSetting", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("key", "viewport_start")
cmd:set_parameter("value", 1000)

local result = command_manager.execute(cmd)
assert(result.success, "SetProjectSetting should succeed: " .. tostring(result.error_message))

local settings = database.get_project_settings("test_project")
assert(settings.viewport_start == 1000, "Setting should be persisted")

-- Test 2: Set complex value (table)
print("Test 2: Set complex value (table)")
local complex_value = {
    start = 0,
    duration = 5000,
    zoom = 1.5
}

local complex_cmd = Command.create("SetProjectSetting", "test_project")
complex_cmd:set_parameter("project_id", "test_project")
complex_cmd:set_parameter("key", "viewport_state")
complex_cmd:set_parameter("value", complex_value)

result = command_manager.execute(complex_cmd)
assert(result.success, "Complex value should succeed")

settings = database.get_project_settings("test_project")
assert(settings.viewport_state, "Complex setting should exist")
assert(settings.viewport_state.start == 0, "Nested start should be 0")
assert(settings.viewport_state.duration == 5000, "Nested duration should be 5000")
assert(settings.viewport_state.zoom == 1.5, "Nested zoom should be 1.5")

-- Test 3: Multiple settings coexist
print("Test 3: Multiple settings coexist")
local setting_a_cmd = Command.create("SetProjectSetting", "test_project")
setting_a_cmd:set_parameter("project_id", "test_project")
setting_a_cmd:set_parameter("key", "setting_a")
setting_a_cmd:set_parameter("value", "value_a")
command_manager.execute(setting_a_cmd)

local setting_b_cmd = Command.create("SetProjectSetting", "test_project")
setting_b_cmd:set_parameter("project_id", "test_project")
setting_b_cmd:set_parameter("key", "setting_b")
setting_b_cmd:set_parameter("value", 42)
command_manager.execute(setting_b_cmd)

local setting_c_cmd = Command.create("SetProjectSetting", "test_project")
setting_c_cmd:set_parameter("project_id", "test_project")
setting_c_cmd:set_parameter("key", "setting_c")
setting_c_cmd:set_parameter("value", true)
command_manager.execute(setting_c_cmd)

settings = database.get_project_settings("test_project")
assert(settings.setting_a == "value_a", "String setting should exist")
assert(settings.setting_b == 42, "Number setting should exist")
assert(settings.setting_c == true, "Boolean setting should exist")
-- Previous settings should still exist
assert(settings.viewport_start == 1000, "Previous settings should persist")

-- Test 4: Delete setting (nil value)
print("Test 4: Delete setting (nil value)")
local delete_cmd = Command.create("SetProjectSetting", "test_project")
delete_cmd:set_parameter("project_id", "test_project")
delete_cmd:set_parameter("key", "setting_a")
delete_cmd:set_parameter("value", nil)

result = command_manager.execute(delete_cmd)
assert(result.success, "Delete should succeed")

settings = database.get_project_settings("test_project")
assert(settings.setting_a == nil, "Setting should be deleted")
assert(settings.setting_b == 42, "Other settings should remain")

-- Test 5: Empty key fails
print("Test 5: Empty key fails (expect error)")
local empty_key_cmd = Command.create("SetProjectSetting", "test_project")
empty_key_cmd:set_parameter("project_id", "test_project")
empty_key_cmd:set_parameter("key", "")
empty_key_cmd:set_parameter("value", "test")

result = command_manager.execute(empty_key_cmd)
assert(not result.success, "Empty key should fail")

print("✅ test_set_project_setting.lua passed")
