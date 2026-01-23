#!/usr/bin/env luajit

-- Tests for MoveToBin command (unified bin and clip moving)
require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local tag_service = require('core.tag_service')
local uuid = require('uuid')

local TEST_DB = "/tmp/jve/test_move_to_bin.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
local clip_id_1 = uuid.generate()
local clip_id_2 = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Move To Bin Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        created_at, modified_at)
    VALUES ('test_seq', 'test_project', 'Test Seq', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);

    INSERT OR IGNORE INTO tag_namespaces (id, display_name) VALUES ('bin', 'Bins');

    INSERT INTO media (id, project_id, name, file_path, created_at, modified_at, fps_numerator, fps_denominator, duration_frames)
    VALUES ('%s', 'test_project', 'Clip 1', '/path/1.mov', %d, %d, 30, 1, 100);
    INSERT INTO media (id, project_id, name, file_path, created_at, modified_at, fps_numerator, fps_denominator, duration_frames)
    VALUES ('%s', 'test_project', 'Clip 2', '/path/2.mov', %d, %d, 30, 1, 100);
]], now, now, now, now, clip_id_1, now, now, clip_id_2, now, now))

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

local function get_clip_assignments()
    return tag_service.list_master_clip_assignments("test_project")
end

print("=== MoveToBin Command Tests ===")

-- Create some bins for testing
local bin_a_id = uuid.generate()
local bin_b_id = uuid.generate()
local bin_c_id = uuid.generate()

local function create_bin(id, name, parent_id)
    local cmd = Command.create("NewBin", "test_project")
    cmd:set_parameter("project_id", "test_project")
    cmd:set_parameter("bin_id", id)
    cmd:set_parameter("name", name)
    if parent_id then
        cmd:set_parameter("parent_id", parent_id)
    end
    local result = command_manager.execute(cmd)
    assert(result.success, "Failed to create bin: " .. tostring(result.error_message))
end

create_bin(bin_a_id, "Bin A", nil)
create_bin(bin_b_id, "Bin B", nil)
create_bin(bin_c_id, "Bin C", bin_a_id)  -- C is child of A

-- Test 1: Move clips to a bin
print("Test 1: Move clips to a bin")
local cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", { clip_id_1, clip_id_2 })
cmd:set_parameter("target_bin_id", bin_a_id)
local result = command_manager.execute(cmd)
assert(result.success, "MoveToBin should succeed: " .. tostring(result.error_message))

local assignments = get_clip_assignments()
assert(assignments[clip_id_1] == bin_a_id, "Clip 1 should be in Bin A")
assert(assignments[clip_id_2] == bin_a_id, "Clip 2 should be in Bin A")

-- Test 2: Undo clip move
print("Test 2: Undo clip move")
local undo_result = command_manager.undo()
assert(undo_result.success, "Undo should succeed")

assignments = get_clip_assignments()
assert(assignments[clip_id_1] == nil, "Clip 1 should be unassigned after undo")
assert(assignments[clip_id_2] == nil, "Clip 2 should be unassigned after undo")

-- Test 3: Redo clip move
print("Test 3: Redo clip move")
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed")

assignments = get_clip_assignments()
assert(assignments[clip_id_1] == bin_a_id, "Clip 1 should be in Bin A after redo")
assert(assignments[clip_id_2] == bin_a_id, "Clip 2 should be in Bin A after redo")

-- Test 4: Move bin to new parent
print("Test 4: Move bin to new parent")
local bin_b = find_bin_by_id(bin_b_id)
assert(bin_b.parent_id == nil, "Bin B should start at root")

cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", { bin_b_id })
cmd:set_parameter("target_bin_id", bin_a_id)
result = command_manager.execute(cmd)
assert(result.success, "MoveToBin for bin should succeed: " .. tostring(result.error_message))

bin_b = find_bin_by_id(bin_b_id)
assert(bin_b.parent_id == bin_a_id, "Bin B should now be under Bin A")

-- Test 5: Undo bin move
print("Test 5: Undo bin move")
undo_result = command_manager.undo()
assert(undo_result.success, "Undo bin move should succeed")

bin_b = find_bin_by_id(bin_b_id)
assert(bin_b.parent_id == nil, "Bin B should be back at root after undo")

-- Test 6: Redo bin move
print("Test 6: Redo bin move")
redo_result = command_manager.redo()
assert(redo_result.success, "Redo bin move should succeed")

bin_b = find_bin_by_id(bin_b_id)
assert(bin_b.parent_id == bin_a_id, "Bin B should be under Bin A after redo")

-- Test 7: Cannot move bin into its descendant
print("Test 7: Cannot move bin into its descendant (expect error)")
cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", { bin_a_id })
cmd:set_parameter("target_bin_id", bin_c_id)  -- C is child of A
result = command_manager.execute(cmd)
assert(not result.success, "Moving bin into its descendant should fail")

-- Test 8: Move bin to root
print("Test 8: Move bin to root")
cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", { bin_c_id })
cmd:set_parameter("target_bin_id", nil)
result = command_manager.execute(cmd)
assert(result.success, "Move to root should succeed: " .. tostring(result.error_message))

local bin_c = find_bin_by_id(bin_c_id)
assert(bin_c.parent_id == nil, "Bin C should now be at root")

-- Test 9: Move clips to different bin
print("Test 9: Move clips to different bin")
cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", { clip_id_1 })
cmd:set_parameter("target_bin_id", bin_b_id)
result = command_manager.execute(cmd)
assert(result.success, "Move clip to different bin should succeed")

assignments = get_clip_assignments()
assert(assignments[clip_id_1] == bin_b_id, "Clip 1 should now be in Bin B")
assert(assignments[clip_id_2] == bin_a_id, "Clip 2 should still be in Bin A")

-- Test 10: Unassign clips (move to nil)
print("Test 10: Unassign clips (move to nil)")
cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", { clip_id_1, clip_id_2 })
cmd:set_parameter("target_bin_id", nil)
result = command_manager.execute(cmd)
assert(result.success, "Unassign should succeed")

assignments = get_clip_assignments()
assert(assignments[clip_id_1] == nil, "Clip 1 should be unassigned")
assert(assignments[clip_id_2] == nil, "Clip 2 should be unassigned")

-- Test 11: Empty entity list is no-op
print("Test 11: Empty entity list is no-op")
cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", {})
cmd:set_parameter("target_bin_id", bin_a_id)
result = command_manager.execute(cmd)
assert(result.success, "Empty list should succeed (no-op)")

-- Test 12: Move to nonexistent bin fails
print("Test 12: Move to nonexistent bin fails (expect error)")
cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", { clip_id_1 })
cmd:set_parameter("target_bin_id", "nonexistent_bin_id")
result = command_manager.execute(cmd)
assert(not result.success, "Move to nonexistent bin should fail")

-- Test 13: Mixed bins and clips in single command
print("Test 13: Mixed bins and clips in single command")
-- First, put clip_1 back in bin_a
cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", { clip_id_1 })
cmd:set_parameter("target_bin_id", bin_a_id)
command_manager.execute(cmd)

-- Move both bin_c and clip_1 to bin_b
cmd = Command.create("MoveToBin", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("entity_ids", { bin_c_id, clip_id_1 })
cmd:set_parameter("target_bin_id", bin_b_id)
result = command_manager.execute(cmd)
assert(result.success, "Mixed move should succeed: " .. tostring(result.error_message))

bin_c = find_bin_by_id(bin_c_id)
assignments = get_clip_assignments()
assert(bin_c.parent_id == bin_b_id, "Bin C should be under Bin B")
assert(assignments[clip_id_1] == bin_b_id, "Clip 1 should be in Bin B")

-- Test 14: Undo mixed move
print("Test 14: Undo mixed move restores both")
undo_result = command_manager.undo()
assert(undo_result.success, "Undo mixed move should succeed")

bin_c = find_bin_by_id(bin_c_id)
assignments = get_clip_assignments()
assert(bin_c.parent_id == nil, "Bin C should be back at root after undo")
assert(assignments[clip_id_1] == bin_a_id, "Clip 1 should be back in Bin A after undo")

print("✅ test_move_to_bin.lua passed")
