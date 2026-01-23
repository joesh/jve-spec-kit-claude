#!/usr/bin/env luajit

-- Tests for bin management commands: NewBin, DeleteBin, RenameItem (bin type)

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local tag_service = require('core.tag_service')
local uuid = require('uuid')

local TEST_DB = "/tmp/jve/test_bin_commands.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Bin Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        created_at, modified_at)
    VALUES ('test_seq', 'test_project', 'Test Seq', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);

    -- Initialize the bin namespace
    INSERT OR IGNORE INTO tag_namespaces (id, display_name) VALUES ('bin', 'Bins');
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

local function get_bins()
    return tag_service.list("test_project")
end

local function find_bin_by_id(id)
    for _, bin in ipairs(get_bins()) do
        if bin.id == id then
            return bin
        end
    end
    return nil
end

local function find_bin_by_name(name)
    for _, bin in ipairs(get_bins()) do
        if bin.name == name then
            return bin
        end
    end
    return nil
end

print("=== Bin Management Commands Tests ===")

-- Test 1: NewBin creates a bin
print("Test 1: NewBin creates a bin")
local bin_id_1 = uuid.generate()
local new_bin_cmd = Command.create("NewBin", "test_project")
new_bin_cmd:set_parameter("project_id", "test_project")
new_bin_cmd:set_parameter("bin_id", bin_id_1)
new_bin_cmd:set_parameter("name", "Test Bin 1")

local result = command_manager.execute(new_bin_cmd)
assert(result.success, "NewBin failed: " .. tostring(result.error_message))

local bin1 = find_bin_by_id(bin_id_1)
assert(bin1, "Bin should exist after NewBin")
assert(bin1.name == "Test Bin 1", "Bin name should be 'Test Bin 1'")

-- Test 2: NewBin with empty name defaults to "New Bin"
print("Test 2: NewBin with empty name defaults to 'New Bin'")
local bin_id_2 = uuid.generate()
local empty_name_cmd = Command.create("NewBin", "test_project")
empty_name_cmd:set_parameter("project_id", "test_project")
empty_name_cmd:set_parameter("bin_id", bin_id_2)
empty_name_cmd:set_parameter("name", "")

result = command_manager.execute(empty_name_cmd)
assert(result.success, "NewBin with empty name failed: " .. tostring(result.error_message))

local bin2 = find_bin_by_id(bin_id_2)
assert(bin2, "Bin with empty name should exist")
assert(bin2.name == "New Bin", "Empty name should default to 'New Bin', got: " .. tostring(bin2.name))

-- Test 3: Undo NewBin removes the bin
print("Test 3: Undo NewBin removes the bin")
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo NewBin failed: " .. tostring(undo_result.error_message))

local bin2_after_undo = find_bin_by_id(bin_id_2)
assert(bin2_after_undo == nil, "Bin should be removed after undo")

-- Test 4: Redo NewBin restores the bin
print("Test 4: Redo NewBin restores the bin")
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo NewBin failed: " .. tostring(redo_result.error_message))

local bin2_after_redo = find_bin_by_id(bin_id_2)
assert(bin2_after_redo, "Bin should be restored after redo")
assert(bin2_after_redo.name == "New Bin", "Bin name should be preserved after redo")

-- Test 5: NewBin with nonexistent parent fails
print("Test 5: NewBin with nonexistent parent fails (expect error)")
local orphan_cmd = Command.create("NewBin", "test_project")
orphan_cmd:set_parameter("project_id", "test_project")
orphan_cmd:set_parameter("bin_id", uuid.generate())
orphan_cmd:set_parameter("name", "Orphan Bin")
orphan_cmd:set_parameter("parent_id", "nonexistent_parent_id")

result = command_manager.execute(orphan_cmd)
assert(not result.success, "NewBin with nonexistent parent should fail")

-- Test 6: DeleteBin removes a bin
print("Test 6: DeleteBin removes a bin")
local delete_cmd = Command.create("DeleteBin", "test_project")
delete_cmd:set_parameter("project_id", "test_project")
delete_cmd:set_parameter("bin_id", bin_id_1)
delete_cmd:set_parameter("deleted_bin_definition", {}) -- Will be filled by executor

result = command_manager.execute(delete_cmd)
assert(result.success, "DeleteBin failed: " .. tostring(result.error_message))

local bin1_after_delete = find_bin_by_id(bin_id_1)
assert(bin1_after_delete == nil, "Bin should be removed after DeleteBin")

-- Test 7: Undo DeleteBin restores the bin
print("Test 7: Undo DeleteBin restores the bin")
undo_result = command_manager.undo()
assert(undo_result.success, "Undo DeleteBin failed: " .. tostring(undo_result.error_message))

local bin1_restored = find_bin_by_id(bin_id_1)
assert(bin1_restored, "Bin should be restored after undo DeleteBin")
assert(bin1_restored.name == "Test Bin 1", "Bin name should be preserved")

-- Test 8: DeleteBin on nonexistent bin fails
print("Test 8: DeleteBin on nonexistent bin fails (expect error)")
local delete_ghost_cmd = Command.create("DeleteBin", "test_project")
delete_ghost_cmd:set_parameter("project_id", "test_project")
delete_ghost_cmd:set_parameter("bin_id", "ghost_bin_id")
delete_ghost_cmd:set_parameter("deleted_bin_definition", {})

result = command_manager.execute(delete_ghost_cmd)
assert(not result.success, "DeleteBin on nonexistent bin should fail")

-- Test 9: RenameItem (bin) changes bin name
print("Test 9: RenameItem (bin) changes bin name")
local rename_cmd = Command.create("RenameItem", "test_project")
rename_cmd:set_parameter("project_id", "test_project")
rename_cmd:set_parameter("target_type", "bin")
rename_cmd:set_parameter("target_id", bin_id_1)
rename_cmd:set_parameter("new_name", "Renamed Bin")
rename_cmd:set_parameter("previous_name", "Test Bin 1")

result = command_manager.execute(rename_cmd)
assert(result.success, "RenameItem (bin) failed: " .. tostring(result.error_message))

local renamed_bin = find_bin_by_id(bin_id_1)
assert(renamed_bin, "Bin should still exist after rename")
assert(renamed_bin.name == "Renamed Bin", "Bin should have new name, got: " .. tostring(renamed_bin.name))

-- Test 10: Undo RenameItem restores original name
print("Test 10: Undo RenameItem restores original name")
undo_result = command_manager.undo()
assert(undo_result.success, "Undo RenameItem failed: " .. tostring(undo_result.error_message))

local reverted_bin = find_bin_by_id(bin_id_1)
assert(reverted_bin.name == "Test Bin 1", "Bin name should be restored, got: " .. tostring(reverted_bin.name))

-- Test 11: RenameItem with empty name fails
print("Test 11: RenameItem with empty name fails (expect error)")
local empty_rename_cmd = Command.create("RenameItem", "test_project")
empty_rename_cmd:set_parameter("project_id", "test_project")
empty_rename_cmd:set_parameter("target_type", "bin")
empty_rename_cmd:set_parameter("target_id", bin_id_1)
empty_rename_cmd:set_parameter("new_name", "   ")  -- whitespace only
empty_rename_cmd:set_parameter("previous_name", "Test Bin 1")

result = command_manager.execute(empty_rename_cmd)
assert(not result.success, "RenameItem with empty name should fail")

-- Test 12: RenameItem on nonexistent bin fails
print("Test 12: RenameItem on nonexistent bin fails (expect error)")
local rename_ghost_cmd = Command.create("RenameItem", "test_project")
rename_ghost_cmd:set_parameter("project_id", "test_project")
rename_ghost_cmd:set_parameter("target_type", "bin")
rename_ghost_cmd:set_parameter("target_id", "ghost_bin_id")
rename_ghost_cmd:set_parameter("new_name", "Ghost Name")
rename_ghost_cmd:set_parameter("previous_name", "")

result = command_manager.execute(rename_ghost_cmd)
assert(not result.success, "RenameItem on nonexistent bin should fail")

-- Test 13: Multiple undo/redo cycles maintain integrity
print("Test 13: Multiple undo/redo cycles maintain integrity")
-- Redo the rename we undid
redo_result = command_manager.redo()
assert(redo_result.success, "Redo rename failed")
assert(find_bin_by_id(bin_id_1).name == "Renamed Bin", "After redo, name should be 'Renamed Bin'")

for i = 1, 3 do
    local u = command_manager.undo()
    assert(u.success, "Undo cycle " .. i .. " failed")
    assert(find_bin_by_id(bin_id_1).name == "Test Bin 1", "After undo cycle " .. i)

    local r = command_manager.redo()
    assert(r.success, "Redo cycle " .. i .. " failed")
    assert(find_bin_by_id(bin_id_1).name == "Renamed Bin", "After redo cycle " .. i)
end

print("✅ test_bin_commands.lua passed")
