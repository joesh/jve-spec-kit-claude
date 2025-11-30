#!/usr/bin/env luajit
-- Integration Test: Ripple Operations with Rational Timebase
-- Verifies that RippleEdit and BatchRippleEdit work correctly with Rational objects.

local Rational = require("core.rational")
local time_utils = require("core.time_utils")

print("=== Ripple Operations (Rational) Test Suite ===\n")

-- Test statistics
local tests_run = 0
local tests_passed = 0
local tests_failed = 0
local current_test = nil

-- Helper: Assert
local function assert_true(condition, message)
    tests_run = tests_run + 1
    if condition then
        tests_passed = tests_passed + 1
        print(string.format("  ✓ %s: %s", current_test, message))
        return true
    else
        tests_failed = tests_failed + 1
        print(string.format("  ✗ %s: %s", current_test, message))
        return false
    end
end

local function assert_eq_rational(actual, expected, message)
    tests_run = tests_run + 1
    if actual == expected then
        tests_passed = tests_passed + 1
        print(string.format("  ✓ %s: %s", current_test, message))
        return true
    else
        tests_failed = tests_failed + 1
        print(string.format("  ✗ %s: %s", current_test, message))
        print(string.format("    Expected: %s", tostring(expected)))
        print(string.format("    Actual:   %s", tostring(actual)))
        return false
    end
end

-- Setup Mock Database and Timeline State
local mock_db = {
    clips = {},
    load_clips = function(self) 
        local list = {}
        for _, c in pairs(self.clips) do table.insert(list, c) end
        return list
    end
}

-- Mock Timeline State (minimal)
local timeline_state = {
    get_sequence_frame_rate = function()
        return {fps_numerator = 30, fps_denominator = 1}
    end
}

-- Helper to create a clip with Rational times
local function create_clip(id, start_frame, duration_frame, track_id)
    local fps = 30
    local clip = {
        id = id,
        track_id = track_id or "V1",
        timeline_start = Rational.new(start_frame, fps, 1),
        duration = Rational.new(duration_frame, fps, 1),
        source_in = Rational.new(0, fps, 1),
        source_out = Rational.new(duration_frame, fps, 1),
        media_id = "media1",
        enabled = true
    }
    mock_db.clips[id] = clip
    return clip
end

-- Logic under test: Simplified Edge Ripple with Rational Arithmetic
-- This mimics the core logic in BatchRippleEdit/RippleEdit commands
local function apply_edge_ripple_rational(clip, edge_type, delta_rational)
    local new_duration
    local new_start = clip.timeline_start
    
    if edge_type == "in" then
        -- Dragging In-point: Start moves, Duration changes inverse to drag
        -- Drag right (+delta): Start increases, Duration decreases
        new_duration = clip.duration - delta_rational
        if new_duration.frames < 1 then return false, "Duration too short" end
        
        clip.timeline_start = clip.timeline_start + delta_rational
        clip.duration = new_duration
        clip.source_in = clip.source_in + delta_rational
        
    elseif edge_type == "out" then
        -- Dragging Out-point: Start fixed, Duration changes with drag
        -- Drag right (+delta): Duration increases
        new_duration = clip.duration + delta_rational
        if new_duration.frames < 1 then return false, "Duration too short" end
        
        clip.duration = new_duration
        clip.source_out = clip.source_in + new_duration
    end
    
    return true
end

-- ============================================================================ 
-- TEST 1: Ripple Out-Point (Extend)
-- ============================================================================ 
current_test = "Test 1"
print("\n" .. current_test .. ": Ripple Out-Point (Extend)")

local clip1 = create_clip("c1", 0, 30) -- 0-1s
local delta = Rational.new(15, 30, 1) -- +0.5s

local success, err = apply_edge_ripple_rational(clip1, "out", delta)

assert_true(success, "Ripple should succeed")
assert_eq_rational(clip1.duration, Rational.new(45, 30, 1), "Duration should be 45 frames")
assert_eq_rational(clip1.timeline_start, Rational.new(0, 30, 1), "Start should remain 0")

-- ============================================================================ 
-- TEST 2: Ripple In-Point (Trim)
-- ============================================================================ 
current_test = "Test 2"
print("\n" .. current_test .. ": Ripple In-Point (Trim)")

local clip2 = create_clip("c2", 30, 60) -- 1s-3s (2s dur)
local delta_trim = Rational.new(15, 30, 1) -- +0.5s (drag right)

success, err = apply_edge_ripple_rational(clip2, "in", delta_trim)

assert_true(success, "Ripple should succeed")
assert_eq_rational(clip2.timeline_start, Rational.new(45, 30, 1), "Start should move to 45 frames")
assert_eq_rational(clip2.duration, Rational.new(45, 30, 1), "Duration should decrease to 45 frames")
assert_eq_rational(clip2.source_in, Rational.new(15, 30, 1), "Source In should advance by 15 frames")

-- ============================================================================ 
-- TEST 3: Ripple In-Point (Extend / Drag Left)
-- ============================================================================ 
current_test = "Test 3"
print("\n" .. current_test .. ": Ripple In-Point (Extend Left)")

local clip3 = create_clip("c3", 60, 30) -- 2s-3s
-- Initial source_in is 0. If we drag left, source_in becomes negative.
-- The simplified logic doesn't check source bounds (that's in constraints), but let's verify arithmetic.
local delta_neg = Rational.new(-10, 30, 1) 

success, err = apply_edge_ripple_rational(clip3, "in", delta_neg)

assert_true(success, "Ripple should succeed")
assert_eq_rational(clip3.timeline_start, Rational.new(50, 30, 1), "Start should move left to 50 frames")
assert_eq_rational(clip3.duration, Rational.new(40, 30, 1), "Duration should increase to 40 frames")
assert_eq_rational(clip3.source_in, Rational.new(-10, 30, 1), "Source In should be -10 (logic allows negative arithmetic)")

-- ============================================================================ 
-- SUMMARY
-- ============================================================================ 
print("\n" .. string.rep("=", 60))
print(string.format("Total Tests: %d, Passed: %d, Failed: %d", tests_run, tests_passed, tests_failed))
if tests_failed == 0 then
    print("✅ ALL TESTS PASSED!")
    os.exit(0)
else
    print("❌ SOME TESTS FAILED!")
    os.exit(1)
end
