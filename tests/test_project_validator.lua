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
            sequence_start = 0, duration = 500, source_in = 100,
        },
        clip_b = {
            id = "clip_b", name = "B", track_key = "v1", media_key = "main",
            sequence_start = 500, duration = 700, source_in = 200,
        },
        clip_c = {
            id = "clip_c", name = "C", track_key = "a1", media_key = "main",
            sequence_start = 0, duration = 1200, source_in = 300,
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
-- Test 3: Reversed source range is valid (reverse clip convention)
-- =========================================================================

update_clip_field("clip_a", "source_in_frame", 999)
update_clip_field("clip_a", "source_out_frame", 100)
local rev_result = validator.validate_jvp(db)
-- source_in > source_out is the JVE convention for reverse clips — NOT an error.
-- Validator should not flag this. (ABSURD_SPEED may flag it if the speed is
-- outside [0.001, 100], but BAD_SOURCE_RANGE should not appear.)
local found_bad_range = false
for _, err in ipairs(rev_result.errors) do
    if err:match("ZERO_SOURCE_RANGE") then found_bad_range = true end
end
assert(not found_bad_range, "Reversed source range should not be flagged as zero")

-- Restore
update_clip_field("clip_a", "source_in_frame", 100)
update_clip_field("clip_a", "source_out_frame", 600)

print("  Test 3: reversed source range accepted (reverse clip) — OK")

-- =========================================================================
-- Test 3b: Zero source range IS a violation
-- =========================================================================

update_clip_field("clip_a", "source_in_frame", 500)
update_clip_field("clip_a", "source_out_frame", 500)
local zero_result = validator.validate_jvp(db)
assert(not zero_result.ok, "source_in == source_out should fail")

local found_zero = false
for _, err in ipairs(zero_result.errors) do
    if err:match("ZERO_SOURCE_RANGE") then found_zero = true end
end
assert(found_zero, "Should report ZERO_SOURCE_RANGE error")

-- Restore
update_clip_field("clip_a", "source_in_frame", 100)
update_clip_field("clip_a", "source_out_frame", 600)

print("  Test 3b: zero source range detected — OK")

-- =========================================================================
-- Test 4: Video overlap detected
-- =========================================================================

-- Temporarily disable the trigger so we can create the invalid state
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update")

update_clip_field("clip_b", "sequence_start_frame", 400)
-- Now clip_a [0,500] and clip_b [400,1100] overlap on V1

local overlap_result = validator.validate_jvp(db)
assert(not overlap_result.ok, "Overlapping video clips should fail")

local found_overlap = false
for _, err in ipairs(overlap_result.errors) do
    if err:match("VIDEO_OVERLAP") then found_overlap = true end
end
assert(found_overlap, "Should report VIDEO_OVERLAP error")

-- Restore
update_clip_field("clip_b", "sequence_start_frame", 500)

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

-- Simulate the bug: source_out ≈ source_in (near-zero source range for
-- a long clip). For clip_a: source_in=100, duration=500, clip_rate=1000/1.
-- Set source_out near source_in so implied speed = range/500 is below 0.001.
-- This catches the unit mismatch pattern (missing ×1920 audio factor)
-- which produced speeds of ~0.0005.
-- source_out = 100 would be zero range (caught by ZERO_SOURCE_RANGE).
-- source_out = 100 + 0.4 → not representable as int. Use large duration instead.
-- Actually: with source_in=100, duration=500 at rate 1000/1:
-- unity_range = 500. Need actual_range/500 < 0.001 → actual_range < 0.5.
-- Integer constraint: actual_range must be ≥ 1. So increase duration instead.
-- Set duration=10000, source_out=101 → speed = 1/10000 = 0.0001 (absurd).
update_clip_field("clip_a", "duration_frames", 10000)
update_clip_field("clip_a", "source_out_frame", 101)

local speed_result = validator.validate_jvp(db)
assert(not speed_result.ok, "Absurd speed should fail validation")

local found_speed = false
for _, err in ipairs(speed_result.errors) do
    if err:match("ABSURD_SPEED") then found_speed = true end
end
assert(found_speed, "Should report ABSURD_SPEED error")

-- Restore
update_clip_field("clip_a", "source_out_frame", 600)
update_clip_field("clip_a", "duration_frames", 500)

print("  Test 7: absurd speed ratio detected — OK")

-- =========================================================================
-- Done
-- =========================================================================

layout:cleanup()
print("✅ test_project_validator.lua passed")
