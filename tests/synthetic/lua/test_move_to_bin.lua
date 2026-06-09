#!/usr/bin/env luajit

-- Tests for MoveToBin command (unified bin and clip moving)
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database        = require('core.database')
local command_manager = require('core.command_manager')
local Command         = require('command')
local tag_service     = require('core.tag_service')
local uuid            = require('uuid')
local Project         = require('models.project')
local Sequence        = require('models.sequence')
local Media           = require('models.media')

local TEST_DB = "/tmp/jve/test_move_to_bin.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

-- Ensure schema is loaded before using models
db:exec(require('import_schema'))

-- ---------------------------------------------------------------------------
-- Fixtures (SQL Isolation)
-- ---------------------------------------------------------------------------

local project_id = "test_project"
Project.create("Move To Bin Test Project", {
    id   = project_id,
    fps_mismatch_policy = "resample",
    settings = {
        master_clock_hz = 192000,
        default_fps = { num = 24, den = 1 }
    }
}):save()

local seq_id = "test_seq"
Sequence.create("Test Seq", project_id, { fps_numerator = 30, fps_denominator = 1 }, 1920, 1080, {
    id         = seq_id,
    kind       = "sequence",
    audio_sample_rate = 48000,
    view_start_frame = 0,
    view_duration_frames = 240,
    playhead_frame = 0,
}):save()

-- Ensure bin namespace exists
db:exec("INSERT OR IGNORE INTO tag_namespaces (id, display_name) VALUES ('bin', 'Bins')")

local clip_id_1 = uuid.generate()
Media.create({
    id         = clip_id_1,
    project_id = project_id,
    name       = "Clip 1",
    file_path  = "/path/1.mov",
    fps_numerator   = 30,
    fps_denominator = 1,
    duration_frames = 100,
}):save()

local clip_id_2 = uuid.generate()
Media.create({
    id         = clip_id_2,
    project_id = project_id,
    name       = "Clip 2",
    file_path  = "/path/2.mov",
    fps_numerator   = 30,
    fps_denominator = 1,
    duration_frames = 100,
}):save()

-- Init with REAL timeline_state
command_manager.init(seq_id, project_id)

local function get_bins()
    return tag_service.list(project_id)
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
    local multi = tag_service.list_master_clip_assignments(project_id)
    local flat = {}
    for id, bins in pairs(multi) do
        flat[id] = bins[1]
    end
    return flat
end

print("=== MoveToBin Command Tests ===")

-- Create some bins for testing
local bin_a_id = uuid.generate()
local bin_b_id = uuid.generate()
local bin_c_id = uuid.generate()

local function create_bin(id, name, parent_id)
    local cmd = Command.create("NewBin", project_id)
    cmd:set_parameter("project_id", project_id)
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

-- Test 1: Move clips to a bin (from unassigned)
print("Test 1: Move clips to a bin")
local cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { clip_id_1, clip_id_2 })
cmd:set_parameter("target_bin_id", bin_a_id)
-- source_bin_id = nil (clips are unassigned)
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

cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
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
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { bin_a_id })
cmd:set_parameter("target_bin_id", bin_c_id)  -- C is child of A
result = command_manager.execute(cmd)
assert(not result.success, "Moving bin into its descendant should fail")

-- Test 8: Move bin to root
print("Test 8: Move bin to root")
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { bin_c_id })
cmd:set_parameter("target_bin_id", nil)
result = command_manager.execute(cmd)
assert(result.success, "Move to root should succeed: " .. tostring(result.error_message))

local bin_c = find_bin_by_id(bin_c_id)
assert(bin_c.parent_id == nil, "Bin C should now be at root")

-- Test 9: Move clip to different bin (with explicit source_bin_id)
print("Test 9: Move clips to different bin")
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { clip_id_1 })
cmd:set_parameter("source_bin_id", bin_a_id)
cmd:set_parameter("target_bin_id", bin_b_id)
result = command_manager.execute(cmd)
assert(result.success, "Move clip to different bin should succeed")

assignments = get_clip_assignments()
assert(assignments[clip_id_1] == bin_b_id, "Clip 1 should now be in Bin B")
assert(assignments[clip_id_2] == bin_a_id, "Clip 2 should still be in Bin A")

-- Test 10: Unassign clips (move to nil, source = current bin)
print("Test 10: Unassign clips (move to nil)")
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { clip_id_1 })
cmd:set_parameter("source_bin_id", bin_b_id)
cmd:set_parameter("target_bin_id", nil)
command_manager.execute(cmd)

cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { clip_id_2 })
cmd:set_parameter("source_bin_id", bin_a_id)
cmd:set_parameter("target_bin_id", nil)
command_manager.execute(cmd)

assignments = get_clip_assignments()
assert(assignments[clip_id_1] == nil, "Clip 1 should be unassigned")
assert(assignments[clip_id_2] == nil, "Clip 2 should be unassigned")

-- Test 11: Empty entity list is no-op
print("Test 11: Empty entity list is no-op")
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", {})
cmd:set_parameter("target_bin_id", bin_a_id)
result = command_manager.execute(cmd)
assert(result.success, "Empty list should succeed (no-op)")

-- Test 12: Move to nonexistent bin fails
print("Test 12: Move to nonexistent bin fails (expect error)")
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { clip_id_1 })
cmd:set_parameter("target_bin_id", "nonexistent_bin_id")
result = command_manager.execute(cmd)
assert(not result.success, "Move to nonexistent bin should fail")

-- Test 13: Mixed bins and clips in single command
print("Test 13: Mixed bins and clips in single command")
-- First, put clip_1 in bin_a
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { clip_id_1 })
cmd:set_parameter("target_bin_id", bin_a_id)
-- source_bin_id = nil (unassigned)
command_manager.execute(cmd)

-- Move both bin_c and clip_1 to bin_b
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { bin_c_id, clip_id_1 })
cmd:set_parameter("source_bin_id", bin_a_id)
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

-- Test 15: Nonexistent source_bin_id fails
print("Test 15: Nonexistent source_bin_id fails (expect error)")
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { clip_id_1 })
cmd:set_parameter("source_bin_id", "nonexistent_source_id")
cmd:set_parameter("target_bin_id", bin_b_id)
result = command_manager.execute(cmd)
assert(not result.success, "Move with nonexistent source_bin_id should fail")

-- Test 16: source_bin_id == target_bin_id is no-op for clips
print("Test 16: source == target is no-op for clips")
-- First ensure clip_1 is in bin_a
assignments = get_clip_assignments()
local clip1_bin = assignments[clip_id_1]
cmd = Command.create("MoveToBin", project_id)
cmd:set_parameter("project_id", project_id)
cmd:set_parameter("entity_ids", { clip_id_1 })
cmd:set_parameter("source_bin_id", clip1_bin)
cmd:set_parameter("target_bin_id", clip1_bin)
result = command_manager.execute(cmd)
assert(result.success, "source==target should succeed (no-op)")
-- Verify clip is still in same bin, no spurious changes
assignments = get_clip_assignments()
assert(assignments[clip_id_1] == clip1_bin,
    "Clip 1 should remain in same bin after source==target move")

print("✅ test_move_to_bin.lua passed")
