#!/usr/bin/env luajit

-- Test that project_validator catches real invariant violations.
-- Uses real DB — no mocks.

require("test_env")

local ripple_layout = require("tests.helpers.ripple_layout")
local validator = require("tests.helpers.project_validator")

-- =========================================================================
-- Test 1: Clean state passes validation
-- =========================================================================

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_project_validator.db",
    tracks = {
        order = {"v1", "a1"},
        v1 = {id = "track_v1", name = "V1", track_type = "VIDEO", track_index = 1, enabled = 1},
        a1 = {id = "track_a1", name = "A1", track_type = "AUDIO", track_index = 1, enabled = 1},
    },
    clips = {
        order = {"clip_a", "clip_b", "clip_c"},
        clip_a = {
            id = "clip_a", name = "A", track_key = "v1", media_key = "main",
            timeline_start = 0, duration = 500, source_in = 100,
        },
        clip_b = {
            id = "clip_b", name = "B", track_key = "v1", media_key = "main",
            timeline_start = 500, duration = 700, source_in = 200,
        },
        clip_c = {
            id = "clip_c", name = "C", track_key = "a1", media_key = "main",
            timeline_start = 0, duration = 1200, source_in = 300,
        },
    },
})
local db = layout.db

local result = validator.validate_jvp(db)
assert(result.ok, "Clean layout should pass JVP validation: " .. table.concat(result.errors, "; "))

local undo_result = validator.validate_undo_stack(db)
assert(undo_result.ok, "Clean layout should pass undo validation: " .. table.concat(undo_result.errors, "; "))

print("  Test 1: clean state passes — OK")

-- =========================================================================
-- Test 2: Float frame values detected
-- =========================================================================

-- Must use bound parameters — db:exec() with inline floats has quoting issues
local function update_clip_field(clip_id, field, value)
    local stmt = db:prepare(string.format("UPDATE clips SET %s = ? WHERE id = ?", field))
    stmt:bind_value(1, value)
    stmt:bind_value(2, clip_id)
    assert(stmt:exec(), "UPDATE failed")
    stmt:finalize()
end

-- Use duration_frames which has no trigger — inject a float into source_in_frame
-- (source_in has no overlap trigger and won't cause side effects)
update_clip_field("clip_a", "source_in_frame", 100.5)
local float_result = validator.validate_jvp(db)
assert(not float_result.ok, "Float source_in should fail validation")

local found_float = false
for _, err in ipairs(float_result.errors) do
    if err:match("FLOAT_FRAME") then found_float = true end
end
assert(found_float, "Should report FLOAT_FRAME error")

-- Restore
update_clip_field("clip_a", "source_in_frame", 100)

print("  Test 2: float frames detected — OK")

-- =========================================================================
-- Test 3: Source range violation detected
-- =========================================================================

update_clip_field("clip_a", "source_in_frame", 999)
update_clip_field("clip_a", "source_out_frame", 100)
local src_result = validator.validate_jvp(db)
assert(not src_result.ok, "source_in > source_out should fail")

local found_src = false
for _, err in ipairs(src_result.errors) do
    if err:match("BAD_SOURCE_RANGE") then found_src = true end
end
assert(found_src, "Should report BAD_SOURCE_RANGE error")

-- Restore
update_clip_field("clip_a", "source_in_frame", 100)
update_clip_field("clip_a", "source_out_frame", 600)

print("  Test 3: source range violation detected — OK")

-- =========================================================================
-- Test 4: Video overlap detected
-- =========================================================================

-- Temporarily disable the trigger so we can create the invalid state
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update")

update_clip_field("clip_b", "timeline_start_frame", 400)
-- Now clip_a [0,500] and clip_b [400,1100] overlap on V1

local overlap_result = validator.validate_jvp(db)
assert(not overlap_result.ok, "Overlapping video clips should fail")

local found_overlap = false
for _, err in ipairs(overlap_result.errors) do
    if err:match("VIDEO_OVERLAP") then found_overlap = true end
end
assert(found_overlap, "Should report VIDEO_OVERLAP error")

-- Restore
update_clip_field("clip_b", "timeline_start_frame", 500)

print("  Test 4: video overlap detected — OK")

-- =========================================================================
-- Test 5: Orphan parent in undo stack detected
-- =========================================================================

-- Insert a command with a nonexistent parent
db:exec([[
    INSERT INTO commands (id, sequence_number, command_type, command_args,
                          parent_sequence_number, timestamp)
    VALUES ('cmd_1', 1, 'TestCmd', '{}', NULL, 1000)
]])
db:exec([[
    INSERT INTO commands (id, sequence_number, command_type, command_args,
                          parent_sequence_number, timestamp)
    VALUES ('cmd_2', 2, 'TestCmd', '{}', 999, 1001)
]])

local undo_bad = validator.validate_undo_stack(db)
assert(not undo_bad.ok, "Orphan parent should fail undo validation")

local found_orphan = false
for _, err in ipairs(undo_bad.errors) do
    if err:match("ORPHAN_PARENT") then found_orphan = true end
end
assert(found_orphan, "Should report ORPHAN_PARENT error")

-- Cleanup
db:exec("DELETE FROM commands")

print("  Test 5: orphan parent detected — OK")

-- =========================================================================
-- Test 6: Parent ordering violation detected
-- =========================================================================

db:exec([[
    INSERT INTO commands (id, sequence_number, command_type, command_args,
                          parent_sequence_number, timestamp)
    VALUES ('cmd_3', 3, 'TestCmd', '{}', NULL, 1000)
]])
db:exec([[
    INSERT INTO commands (id, sequence_number, command_type, command_args,
                          parent_sequence_number, timestamp)
    VALUES ('cmd_4', 4, 'TestCmd', '{}', 5, 1001)
]])

local order_result = validator.validate_undo_stack(db)
assert(not order_result.ok, "Parent after child should fail")

local found_order = false
for _, err in ipairs(order_result.errors) do
    if err:match("PARENT_AFTER_CHILD") or err:match("ORPHAN_PARENT") then found_order = true end
end
assert(found_order, "Should report ordering error")

-- Cleanup
db:exec("DELETE FROM commands")

print("  Test 6: parent ordering violation detected — OK")

-- =========================================================================
-- Test 7: Absurd speed ratio detected (the unit mismatch bug pattern)
-- =========================================================================

-- Simulate the bug: source_out = source_in + duration (timeline frames)
-- instead of source_in + duration * clip_rate / seq_rate.
-- For clip_a: source_in=100, duration=500, clip_rate=1000/1, seq_rate=1000/1
-- → source_out should be 100 + 500 = 600 (speed 1.0, correct for same-rate)
-- Corrupt it to simulate audio-rate mismatch: source_out = source_in + 2
-- → implied speed = 2/500 = 0.004 (absurdly slow)
update_clip_field("clip_a", "source_out_frame", 102)

local speed_result = validator.validate_jvp(db)
assert(not speed_result.ok, "Absurd speed should fail validation")

local found_speed = false
for _, err in ipairs(speed_result.errors) do
    if err:match("ABSURD_SPEED") then found_speed = true end
end
assert(found_speed, "Should report ABSURD_SPEED error")

-- Restore
update_clip_field("clip_a", "source_out_frame", 600)

print("  Test 7: absurd speed ratio detected — OK")

-- =========================================================================
-- Done
-- =========================================================================

layout:cleanup()
print("✅ test_project_validator.lua passed")
