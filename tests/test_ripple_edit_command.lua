#!/usr/bin/env luajit

-- Test RippleEdit command - comprehensive coverage
-- Tests: edge trimming, downstream ripple, gap closure, undo/redo, clamping

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_manager = require('core.command_manager')
local asserts = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== RippleEdit Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_ripple_edit_command.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Disable overlap triggers
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

-- Insert Project/Sequence (30fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- Helper: execute command with proper event wrapping
local function execute_cmd(cmd)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(cmd)
    command_manager.end_command_event()
    return result
end

-- Helper: undo/redo with proper event wrapping
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

-- Create Media (1000 frames @ 30fps - plenty of room for trimming)
local media = Media.create({
    id = "media_long",
    project_id = "project",
    file_path = "/tmp/jve/long_video.mov",
    name = "Long Video",
    duration_frames = 1000,
    fps_numerator = 30,
    fps_denominator = 1
})
media:save(db)

-- Helper: get clip position/duration
local function get_clip_state(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame, duration_frames, source_in_frame, source_out_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    stmt:exec()
    if stmt:next() then
        local state = {
            start = stmt:value(0),
            duration = stmt:value(1),
            source_in = stmt:value(2),
            source_out = stmt:value(3)
        }
        stmt:finalize()
        return state
    end
    stmt:finalize()
    return nil
end

-- Helper: create a clip
local function create_clip(id, start_frame, duration_frames, source_in)
    source_in = source_in or 0
    local clip = Clip.create("Clip " .. id, "media_long", {
        id = id,
        project_id = "project",
        track_id = "track_v1",
        owner_sequence_id = "sequence",
        master_clip_id = "mc_test",
        timeline_start = start_frame,
        duration = duration_frames,
        source_in = source_in,
        source_out = source_in + duration_frames,
        enabled = true,
        fps_numerator = 30,
        fps_denominator = 1
    })
    assert(clip:save(db), "Failed to save clip " .. id)
    return clip
end

-- Helper: reset timeline
local function reset_timeline()
    db:exec("DELETE FROM clips")
end

-- =============================================================================
-- TEST 1: Ripple trim OUT edge (extend) - downstream clips shift
-- =============================================================================
print("Test 1: Ripple trim OUT edge extends clip and shifts downstream")
reset_timeline()

-- Create two clips: A [0, 100) and B [100, 200)
create_clip("clip_a", 0, 100, 0)
create_clip("clip_b", 100, 100, 0)

-- Extend clip A's out edge by 30 frames
local ripple_cmd = Command.create("RippleEdit", "project")
ripple_cmd:set_parameter("edge_info", {
    clip_id = "clip_a",
    track_id = "track_v1",
    edge_type = "out"
})
ripple_cmd:set_parameter("delta_frames", 30)

local result = execute_cmd(ripple_cmd)
assert(result.success, "RippleEdit should succeed: " .. tostring(result.error_message))

-- Clip A should now be [0, 130)
local state_a = get_clip_state("clip_a")
assert(state_a.start == 0, "Clip A start should stay at 0")
assert(state_a.duration == 130, string.format("Clip A duration should be 130, got %d", state_a.duration))

-- Clip B should ripple to [130, 230)
local state_b = get_clip_state("clip_b")
assert(state_b.start == 130, string.format("Clip B should ripple to 130, got %d", state_b.start))

-- =============================================================================
-- TEST 2: Ripple trim OUT edge (shorten) - downstream clips shift back
-- =============================================================================
print("Test 2: Ripple trim OUT edge shortens clip")
reset_timeline()
create_clip("clip_a", 0, 100, 0)
create_clip("clip_b", 100, 100, 0)

-- Shorten clip A's out edge by 20 frames
local ripple_cmd2 = Command.create("RippleEdit", "project")
ripple_cmd2:set_parameter("edge_info", {
    clip_id = "clip_a",
    track_id = "track_v1",
    edge_type = "out"
})
ripple_cmd2:set_parameter("delta_frames", -20)

result = execute_cmd(ripple_cmd2)
assert(result.success, "RippleEdit should succeed")

-- Clip A should now be [0, 80)
state_a = get_clip_state("clip_a")
assert(state_a.duration == 80, string.format("Clip A duration should be 80, got %d", state_a.duration))

-- Clip B should ripple back to [80, 180)
state_b = get_clip_state("clip_b")
assert(state_b.start == 80, string.format("Clip B should ripple to 80, got %d", state_b.start))

-- =============================================================================
-- TEST 3: Ripple trim IN edge (extend head) - shifts source_in
-- =============================================================================
print("Test 3: Ripple trim IN edge extends head")
reset_timeline()

-- Create clip starting at 100 with source_in at 50 (room to extend head)
create_clip("clip_a", 100, 100, 50)
create_clip("clip_b", 200, 100, 0)

-- Extend clip A's in edge by -30 frames (extending head backward)
local ripple_cmd3 = Command.create("RippleEdit", "project")
ripple_cmd3:set_parameter("edge_info", {
    clip_id = "clip_a",
    track_id = "track_v1",
    edge_type = "in"
})
ripple_cmd3:set_parameter("delta_frames", -30)

result = execute_cmd(ripple_cmd3)
assert(result.success, "RippleEdit should succeed")

-- Clip A should extend: duration = 100 + 30 = 130, source_in = 50 - 30 = 20
state_a = get_clip_state("clip_a")
assert(state_a.duration == 130, string.format("Clip A duration should be 130, got %d", state_a.duration))
assert(state_a.source_in == 20, string.format("Clip A source_in should be 20, got %d", state_a.source_in))

-- =============================================================================
-- TEST 4: Undo ripple edit restores original state
-- =============================================================================
print("Test 4: Undo restores original positions")
reset_timeline()
create_clip("clip_a", 0, 100, 0)
create_clip("clip_b", 100, 100, 0)

local ripple_cmd4 = Command.create("RippleEdit", "project")
ripple_cmd4:set_parameter("edge_info", {
    clip_id = "clip_a",
    track_id = "track_v1",
    edge_type = "out"
})
ripple_cmd4:set_parameter("delta_frames", 50)

result = execute_cmd(ripple_cmd4)
assert(result.success, "RippleEdit should succeed")

-- Verify changed state
state_a = get_clip_state("clip_a")
state_b = get_clip_state("clip_b")
assert(state_a.duration == 150, "Clip A should be extended")
assert(state_b.start == 150, "Clip B should be shifted")

-- Undo
local undo_result = undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- Verify restored state
state_a = get_clip_state("clip_a")
state_b = get_clip_state("clip_b")
assert(state_a.duration == 100, string.format("Clip A should restore to 100, got %d", state_a.duration))
assert(state_b.start == 100, string.format("Clip B should restore to 100, got %d", state_b.start))

-- =============================================================================
-- TEST 5: Redo re-applies the ripple edit
-- =============================================================================
print("Test 5: Redo re-applies ripple edit")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed")

state_a = get_clip_state("clip_a")
state_b = get_clip_state("clip_b")
assert(state_a.duration == 150, "Clip A should be extended again")
assert(state_b.start == 150, "Clip B should be shifted again")

-- =============================================================================
-- TEST 6: Ripple edit with multiple downstream clips
-- =============================================================================
print("Test 6: Multiple downstream clips all shift")
reset_timeline()

create_clip("clip_a", 0, 100, 0)
create_clip("clip_b", 100, 100, 0)
create_clip("clip_c", 200, 100, 0)
create_clip("clip_d", 300, 100, 0)

local ripple_cmd6 = Command.create("RippleEdit", "project")
ripple_cmd6:set_parameter("edge_info", {
    clip_id = "clip_a",
    track_id = "track_v1",
    edge_type = "out"
})
ripple_cmd6:set_parameter("delta_frames", 25)

result = execute_cmd(ripple_cmd6)
assert(result.success, "RippleEdit should succeed")

-- All downstream clips should shift by 25
state_b = get_clip_state("clip_b")
local state_c = get_clip_state("clip_c")
local state_d = get_clip_state("clip_d")

assert(state_b.start == 125, string.format("Clip B should be at 125, got %d", state_b.start))
assert(state_c.start == 225, string.format("Clip C should be at 225, got %d", state_c.start))
assert(state_d.start == 325, string.format("Clip D should be at 325, got %d", state_d.start))

-- =============================================================================
-- TEST 7: Error case - missing edge_info
-- =============================================================================
print("Test 7: Missing edge_info fails")
-- Disable asserts for error case testing
asserts._set_enabled_for_tests(false)
local bad_cmd = Command.create("RippleEdit", "project")
bad_cmd:set_parameter("delta_frames", 30)
-- No edge_info

result = execute_cmd(bad_cmd)
asserts._set_enabled_for_tests(true)
assert(not result.success, "RippleEdit without edge_info should fail")

-- =============================================================================
-- TEST 8: Error case - nonexistent clip
-- =============================================================================
print("Test 8: Nonexistent clip fails")
asserts._set_enabled_for_tests(false)
local bad_cmd2 = Command.create("RippleEdit", "project")
bad_cmd2:set_parameter("edge_info", {
    clip_id = "nonexistent_clip",
    track_id = "track_v1",
    edge_type = "out"
})
bad_cmd2:set_parameter("delta_frames", 30)

result = execute_cmd(bad_cmd2)
asserts._set_enabled_for_tests(true)
assert(not result.success, "RippleEdit with nonexistent clip should fail")

-- =============================================================================
-- TEST 9: Ripple edit with gap_before (close gap)
-- =============================================================================
print("Test 9: Gap before closes gap")
reset_timeline()

-- Create clips with gap: A [0, 100), gap [100, 200), B [200, 300)
create_clip("clip_a", 0, 100, 0)
create_clip("clip_b", 200, 100, 0)

local ripple_cmd9 = Command.create("RippleEdit", "project")
ripple_cmd9:set_parameter("edge_info", {
    clip_id = "clip_b",
    track_id = "track_v1",
    edge_type = "gap_before"
})
ripple_cmd9:set_parameter("delta_frames", -50)  -- Close gap by 50 frames

result = execute_cmd(ripple_cmd9)
assert(result.success, "RippleEdit gap_before should succeed")

-- Clip B should move from 200 to 150
state_b = get_clip_state("clip_b")
assert(state_b.start == 150, string.format("Clip B should move to 150, got %d", state_b.start))

-- =============================================================================
-- TEST 10: Dry run returns preview without modifying
-- =============================================================================
print("Test 10: Dry run returns preview only")
reset_timeline()
create_clip("clip_a", 0, 100, 0)
create_clip("clip_b", 100, 100, 0)

local dry_cmd = Command.create("RippleEdit", "project")
dry_cmd:set_parameter("edge_info", {
    clip_id = "clip_a",
    track_id = "track_v1",
    edge_type = "out"
})
dry_cmd:set_parameter("delta_frames", 30)
dry_cmd:set_parameter("dry_run", true)

result = execute_cmd(dry_cmd)
assert(result.success, "Dry run should succeed")

-- Clips should NOT be modified
state_a = get_clip_state("clip_a")
state_b = get_clip_state("clip_b")
assert(state_a.duration == 100, "Dry run should not modify clip A")
assert(state_b.start == 100, "Dry run should not modify clip B")

print("\n✅ RippleEdit command tests passed")
