#!/usr/bin/env luajit

-- Test RippleDelete command - comprehensive coverage
-- Tests: basic gap deletion, downstream shift, undo/redo, blocking clips, dry run

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local command_manager = require('core.command_manager')
local asserts = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== RippleDelete Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_ripple_delete.db"
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
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v2', 'sequence', 'V2', 'VIDEO', 2, 1);
]])

command_manager.init('sequence', 'project')

-- Create Media
local media = Media.create({
    id = "media_rd",
    project_id = "project",
    file_path = "/tmp/jve/rd_video.mov",
    name = "RD Video",
    duration_frames = 500,
    fps_numerator = 30,
    fps_denominator = 1
})
media:save(db)

-- Helper: execute command with proper event wrapping
local function execute_command(name, params)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
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

-- Helper: create a clip
local function create_clip(id, track_id, start_frame, duration_frames)
    local clip = Clip.create("Clip " .. id, "media_rd", {
        id = id,
        project_id = "project",
        track_id = track_id,
        owner_sequence_id = "sequence",
        timeline_start = start_frame,
        duration = duration_frames,
        source_in = 0,
        source_out = duration_frames,
        enabled = true,
        fps_numerator = 30,
        fps_denominator = 1
    })
    assert(clip:save(db), "Failed to save clip " .. id)
    return clip
end

-- Helper: get clip position
local function get_clip_position(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    stmt:exec()
    if stmt:next() then
        local start = stmt:value(0)
        local dur = stmt:value(1)
        stmt:finalize()
        return start, dur
    end
    stmt:finalize()
    return nil, nil
end

-- Helper: reset timeline
local function reset_timeline()
    db:exec("DELETE FROM clips")
end

-- =============================================================================
-- TEST 1: Basic ripple delete - close gap between clips
-- =============================================================================
print("Test 1: Basic ripple delete closes gap")
reset_timeline()

-- Create timeline: A [0, 100), gap [100, 200), B [200, 300)
create_clip("clip_a", "track_v1", 0, 100)
create_clip("clip_b", "track_v1", 200, 100)

-- Delete the gap at [100, 200)
local result = execute_command("RippleDelete", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    gap_start = 100,
    gap_duration = 100,
    fps_numerator = 30,
    fps_denominator = 1
})
assert(result.success, "RippleDelete should succeed: " .. tostring(result.error_message))

-- Clip B should shift from 200 to 100
local b_start, _ = get_clip_position("clip_b")
assert(b_start == 100, string.format("Clip B should shift to 100, got %d", b_start))

-- =============================================================================
-- TEST 2: Multiple downstream clips shift
-- =============================================================================
print("Test 2: Multiple downstream clips shift")
reset_timeline()

-- Create: A [0, 100), gap [100, 150), B [150, 250), C [250, 350)
create_clip("clip_a", "track_v1", 0, 100)
create_clip("clip_b", "track_v1", 150, 100)
create_clip("clip_c", "track_v1", 250, 100)

-- Delete gap at [100, 150)
result = execute_command("RippleDelete", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    gap_start = 100,
    gap_duration = 50,
    fps_numerator = 30,
    fps_denominator = 1
})
assert(result.success, "RippleDelete should succeed")

-- B: 150-50=100, C: 250-50=200
local b_start2, _ = get_clip_position("clip_b")
local c_start, _ = get_clip_position("clip_c")
assert(b_start2 == 100, string.format("Clip B should shift to 100, got %d", b_start2))
assert(c_start == 200, string.format("Clip C should shift to 200, got %d", c_start))

-- =============================================================================
-- TEST 3: Undo restores original positions
-- =============================================================================
print("Test 3: Undo restores original positions")
local undo_result = undo()
assert(undo_result.success, "Undo should succeed: " .. tostring(undo_result.error_message))

-- B should restore to 150, C to 250
b_start, _ = get_clip_position("clip_b")
c_start, _ = get_clip_position("clip_c")
assert(b_start == 150, string.format("Clip B should restore to 150, got %d", b_start))
assert(c_start == 250, string.format("Clip C should restore to 250, got %d", c_start))

-- =============================================================================
-- TEST 4: Redo re-applies the shift
-- =============================================================================
print("Test 4: Redo re-applies the shift")
local redo_result = redo()
assert(redo_result.success, "Redo should succeed: " .. tostring(redo_result.error_message))

-- B: 100, C: 200 again
b_start, _ = get_clip_position("clip_b")
c_start, _ = get_clip_position("clip_c")
assert(b_start == 100, string.format("Clip B should be at 100 after redo, got %d", b_start))
assert(c_start == 200, string.format("Clip C should be at 200 after redo, got %d", c_start))

-- =============================================================================
-- TEST 5: Cannot delete gap with clip inside
-- =============================================================================
print("Test 5: Cannot delete gap with blocking clip")
reset_timeline()

-- Create: A [0, 100), B [150, 250) - B overlaps with gap [100, 200)
create_clip("clip_a", "track_v1", 0, 100)
create_clip("clip_b", "track_v1", 150, 100)  -- Overlaps gap

-- Try to delete gap [100, 200) - should fail because clip_b overlaps
asserts._set_enabled_for_tests(false)
result = execute_command("RippleDelete", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    gap_start = 100,
    gap_duration = 100,
    fps_numerator = 30,
    fps_denominator = 1
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "RippleDelete should fail when clip overlaps gap")

-- =============================================================================
-- TEST 6: Cross-track validation - clip on other track blocks gap
-- =============================================================================
print("Test 6: Cross-track clip blocks gap deletion")
reset_timeline()

-- Create: v1: A [0, 100), v2: B [150, 250) - B overlaps gap [100, 200)
create_clip("clip_a", "track_v1", 0, 100)
create_clip("clip_b", "track_v2", 150, 100)  -- Different track but overlaps

-- Try to delete gap - should fail
asserts._set_enabled_for_tests(false)
result = execute_command("RippleDelete", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    gap_start = 100,
    gap_duration = 100,
    fps_numerator = 30,
    fps_denominator = 1
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "RippleDelete should fail when cross-track clip overlaps gap")

-- =============================================================================
-- TEST 7: Dry run returns preview without modifying
-- =============================================================================
print("Test 7: Dry run returns preview only")
reset_timeline()
create_clip("clip_a", "track_v1", 0, 100)
create_clip("clip_b", "track_v1", 200, 100)

result = execute_command("RippleDelete", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    gap_start = 100,
    gap_duration = 100,
    fps_numerator = 30,
    fps_denominator = 1,
    dry_run = true
})
assert(result.success, "Dry run should succeed")

-- Clip B should NOT have moved
b_start, _ = get_clip_position("clip_b")
assert(b_start == 200, string.format("Dry run should not move clip B, got %d", b_start))

-- =============================================================================
-- TEST 8: Delete gap at timeline start
-- =============================================================================
print("Test 8: Delete gap at timeline start")
reset_timeline()

-- Create: gap [0, 100), A [100, 200)
create_clip("clip_a", "track_v1", 100, 100)

-- Delete gap at start
result = execute_command("RippleDelete", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    gap_start = 0,
    gap_duration = 100,
    fps_numerator = 30,
    fps_denominator = 1
})
assert(result.success, "RippleDelete at start should succeed")

-- Clip A should move to 0
local a_start, _ = get_clip_position("clip_a")
assert(a_start == 0, string.format("Clip A should shift to 0, got %d", a_start))

-- =============================================================================
-- TEST 9: Error case - missing gap_start
-- =============================================================================
print("Test 9: Missing gap_start fails")
asserts._set_enabled_for_tests(false)
result = execute_command("RippleDelete", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    gap_duration = 100,
    fps_numerator = 30,
    fps_denominator = 1
    -- No gap_start
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "RippleDelete without gap_start should fail")

-- =============================================================================
-- TEST 10: Clips on multiple tracks all shift
-- =============================================================================
print("Test 10: Clips on multiple tracks all shift")
reset_timeline()

-- Create: v1: A [0, 100), v2: empty, both have clips after gap
create_clip("clip_a", "track_v1", 0, 100)
create_clip("clip_b", "track_v1", 200, 100)
create_clip("clip_c", "track_v2", 200, 100)

-- Delete gap [100, 200)
result = execute_command("RippleDelete", {
    project_id = "project",
    sequence_id = "sequence",
    track_id = "track_v1",
    gap_start = 100,
    gap_duration = 100,
    fps_numerator = 30,
    fps_denominator = 1
})
assert(result.success, "RippleDelete should succeed")

-- Both B and C should shift to 100
b_start, _ = get_clip_position("clip_b")
c_start, _ = get_clip_position("clip_c")
assert(b_start == 100, string.format("Clip B should shift to 100, got %d", b_start))
assert(c_start == 100, string.format("Clip C should shift to 100, got %d", c_start))

print("\n✅ RippleDelete command tests passed")
