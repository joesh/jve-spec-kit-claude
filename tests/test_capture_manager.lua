#!/usr/bin/env lua
-- test_capture_manager.lua
-- Test harness for capture_manager ring buffer system

-- Add src/lua to package path
package.path = package.path .. ";../src/lua/?.lua"

local capture_manager = require("bug_reporter.capture_manager")

-- Test utilities
local test_count = 0
local pass_count = 0

local function assert_equal(actual, expected, message)
    test_count = test_count + 1
    if actual == expected then
        pass_count = pass_count + 1
        print("✓ " .. message)
    else
        print("✗ " .. message)
        print("  Expected: " .. tostring(expected))
        print("  Actual:   " .. tostring(actual))
    end
end

local function assert_true(condition, message)
    test_count = test_count + 1
    if condition then
        pass_count = pass_count + 1
        print("✓ " .. message)
    else
        print("✗ " .. message)
    end
end

print("=== Testing CaptureManager ===\n")

-- Test 1: Initialization
print("Test 1: Initialization")
capture_manager:init()
assert_equal(#capture_manager.gesture_ring_buffer, 0, "Gesture buffer starts empty")
assert_equal(#capture_manager.command_ring_buffer, 0, "Command buffer starts empty")
assert_equal(#capture_manager.log_ring_buffer, 0, "Log buffer starts empty")
assert_equal(capture_manager.capture_enabled, true, "Capture enabled by default")
print()

-- Test 2: Log gestures
print("Test 2: Log gestures")
local gesture_id_1 = capture_manager:log_gesture({
    type = "mouse_press",
    x = 100,
    y = 200,
    button = "left"
})
assert_equal(#capture_manager.gesture_ring_buffer, 1, "Gesture buffer has 1 entry")
assert_equal(gesture_id_1, "g1", "First gesture ID is g1")

local gesture_id_2 = capture_manager:log_gesture({
    type = "mouse_move",
    x = 150,
    y = 200
})
assert_equal(#capture_manager.gesture_ring_buffer, 2, "Gesture buffer has 2 entries")
assert_equal(gesture_id_2, "g2", "Second gesture ID is g2")
print()

-- Test 3: Log commands
print("Test 3: Log commands")
local command_id_1 = capture_manager:log_command(
    "RippleEdit",
    {clip_id = "uuid-123", edge = "out", delta_ms = 1500},
    {success = true},
    "g2"  -- Triggered by gesture g2
)
assert_equal(#capture_manager.command_ring_buffer, 1, "Command buffer has 1 entry")
assert_equal(command_id_1, "c1", "First command ID is c1")
assert_equal(capture_manager.command_ring_buffer[1].triggered_by_gesture, "g2", "Command linked to gesture")
print()

-- Test 4: Log messages
print("Test 4: Log messages")
capture_manager:log_message("info", "Test info message")
capture_manager:log_message("warning", "Test warning message")
capture_manager:log_message("error", "Test error message")
assert_equal(#capture_manager.log_ring_buffer, 3, "Log buffer has 3 entries")
assert_equal(capture_manager.log_ring_buffer[1].level, "info", "First log is info")
assert_equal(capture_manager.log_ring_buffer[2].level, "warning", "Second log is warning")
assert_equal(capture_manager.log_ring_buffer[3].level, "error", "Third log is error")
print()

-- Test 5: Gesture count limit (max 200)
print("Test 5: Gesture count limit")
capture_manager:clear_buffers()
for i = 1, 250 do
    capture_manager:log_gesture({type = "mouse_move", x = i, y = i})
end
assert_true(#capture_manager.gesture_ring_buffer <= 200, "Gesture buffer capped at 200")
assert_true(#capture_manager.gesture_ring_buffer > 190, "Gesture buffer near 200 (trimmed some)")
print("  Gesture count: " .. #capture_manager.gesture_ring_buffer)
print()

-- Test 6: Time-based trimming
print("Test 6: Time-based trimming")
capture_manager:clear_buffers()
capture_manager.max_time_ms = 1000  -- Reduce to 1 second for testing

-- Add entries at T=0
capture_manager:log_gesture({type = "mouse_press", x = 1, y = 1})
capture_manager:log_command("TestCommand", {}, {success = true})

-- Simulate time passing by advancing session start time
local original_start = capture_manager.session_start_time
capture_manager.session_start_time = capture_manager.session_start_time - 2  -- 2 seconds ago

-- Add new entry (triggers trim)
capture_manager:log_gesture({type = "mouse_press", x = 2, y = 2})

-- Old entries should be trimmed
assert_true(#capture_manager.gesture_ring_buffer < 3, "Old gestures trimmed by time")
print("  Remaining gestures: " .. #capture_manager.gesture_ring_buffer)

-- Restore for other tests
capture_manager.max_time_ms = 300000
capture_manager.session_start_time = original_start
print()

-- Test 7: Enable/disable capture
print("Test 7: Enable/disable capture")
capture_manager:clear_buffers()
capture_manager:set_enabled(false)
capture_manager:log_gesture({type = "mouse_press", x = 1, y = 1})
assert_equal(#capture_manager.gesture_ring_buffer, 0, "Gesture not logged when disabled")

capture_manager:set_enabled(true)
capture_manager:log_gesture({type = "mouse_press", x = 2, y = 2})
assert_equal(#capture_manager.gesture_ring_buffer, 1, "Gesture logged when enabled")
print()

-- Test 8: Statistics
print("Test 8: Statistics")
capture_manager:clear_buffers()
for i = 1, 10 do
    capture_manager:log_gesture({type = "mouse_move", x = i, y = i})
end
for i = 1, 5 do
    capture_manager:log_command("TestCommand" .. i, {}, {success = true})
end
for i = 1, 15 do
    capture_manager:log_message("info", "Test message " .. i)
end

local stats = capture_manager:get_stats()
assert_equal(stats.gesture_count, 10, "Stats show 10 gestures")
assert_equal(stats.command_count, 5, "Stats show 5 commands")
assert_equal(stats.log_count, 15, "Stats show 15 log entries")
assert_true(stats.memory_estimate_mb < 1, "Memory usage reasonable")
print("  Memory estimate: " .. string.format("%.3f MB", stats.memory_estimate_mb))
print()

-- Test 9: Clear buffers
print("Test 9: Clear buffers")
capture_manager:clear_buffers()
assert_equal(#capture_manager.gesture_ring_buffer, 0, "Gesture buffer cleared")
assert_equal(#capture_manager.command_ring_buffer, 0, "Command buffer cleared")
assert_equal(#capture_manager.log_ring_buffer, 0, "Log buffer cleared")
print()

-- Summary
print("=== Test Summary ===")
print(string.format("Passed: %d / %d tests", pass_count, test_count))
if pass_count == test_count then
    print("✓ All tests passed!")
    os.exit(0)
else
    print("✗ Some tests failed")
    os.exit(1)
end
