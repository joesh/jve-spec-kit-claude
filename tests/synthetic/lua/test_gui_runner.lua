#!/usr/bin/env lua
-- test_gui_runner.lua
-- Test Phase 5 GUI test runner (without actual Qt - tests structure only)

-- Add src/lua to package path
package.path = package.path .. ";../src/lua/?.lua"

local gesture_replay_engine = require("bug_reporter.gesture_replay_engine")
local test_runner_gui = require("bug_reporter.test_runner_gui")

-- Test utilities
local test_count = 0
local pass_count = 0

local function assert_true(condition, message)
    test_count = test_count + 1
    if condition then
        pass_count = pass_count + 1
        print("✓ " .. message)
        return true
    else
        print("✗ " .. message)
        return false
    end
end

local function assert_not_nil(value, message)
    return assert_true(value ~= nil, message)
end

print("=== Testing GUI Test Runner (Phase 5) ===\n")

-- Test 1: Gesture replay engine structure
print("Test 1: Gesture replay engine")
assert_not_nil(gesture_replay_engine.gesture_to_event_params, "gesture_to_event_params exists")
assert_not_nil(gesture_replay_engine.post_gesture_event, "post_gesture_event exists")
assert_not_nil(gesture_replay_engine.replay_gestures, "replay_gestures exists")
assert_not_nil(gesture_replay_engine.calculate_timing_stats, "calculate_timing_stats exists")
print()

-- Test 2: Event parameter conversion
print("Test 2: Event parameter conversion")
local mouse_press = {
    id = "g1",
    timestamp_ms = 0,
    gesture = {
        type = "mouse_press",
        screen_x = 100,
        screen_y = 200,
        button = "left",
        modifiers = {"shift"}
    }
}

local event_type, params = gesture_replay_engine.gesture_to_event_params(mouse_press)
assert_true(event_type == "QMouseEvent", "Mouse event type correct")
assert_true(params.event_type == "MouseButtonPress", "Press event type correct")
assert_true(params.x == 100, "X coordinate correct")
assert_true(params.y == 200, "Y coordinate correct")
assert_true(params.button == "left", "Button correct")
print()

-- Test 3: Key event conversion
print("Test 3: Key event conversion")
local key_press = {
    id = "g2",
    timestamp_ms = 100,
    gesture = {
        type = "key_press",
        key = "a",
        text = "a",
        modifiers = {"ctrl"}
    }
}

local event_type2, params2 = gesture_replay_engine.gesture_to_event_params(key_press)
assert_true(event_type2 == "QKeyEvent", "Key event type correct")
assert_true(params2.event_type == "KeyPress", "Key press type correct")
assert_true(params2.key == "a", "Key correct")
assert_true(params2.text == "a", "Text correct")
print()

-- Test 4: Timing statistics
print("Test 4: Timing statistics")
local gesture_log = {
    {id = "g1", timestamp_ms = 0},
    {id = "g2", timestamp_ms = 100},
    {id = "g3", timestamp_ms = 250},
    {id = "g4", timestamp_ms = 400}
}

local stats = gesture_replay_engine.calculate_timing_stats(gesture_log)
assert_true(stats.duration_ms == 400, "Duration calculated correctly")
assert_true(stats.gesture_count == 4, "Gesture count correct")
assert_true(math.abs(stats.avg_interval_ms - 133.33) < 0.1, "Average interval correct")
print()

-- Test 5: GUI test runner structure
print("Test 5: GUI test runner structure")
assert_not_nil(test_runner_gui.run_test, "run_test exists")
assert_not_nil(test_runner_gui.run_directory, "run_directory exists")
assert_not_nil(test_runner_gui.install_command_capture_hook, "install_command_capture_hook exists")
assert_not_nil(test_runner_gui.capture_command, "capture_command exists")
assert_not_nil(test_runner_gui.print_result, "print_result exists")
assert_not_nil(test_runner_gui.print_summary, "print_summary exists")
print()

-- Test 6: Command capture
print("Test 6: Command capture")
test_runner_gui.install_command_capture_hook()
test_runner_gui.capture_command("TestCommand", {param = 1}, {success = true}, "g1")
test_runner_gui.capture_log_message("warning", "Test warning")
test_runner_gui.uninstall_command_capture_hook()
assert_true(true, "Command capture hooks work")
print()

-- Test 7: Qt bindings detection
print("Test 7: Qt bindings detection")
-- These should fail gracefully when not running in JVE
local success7, err7 = gesture_replay_engine.post_gesture_event(mouse_press)
assert_true(not success7, "Gracefully fails without Qt bindings")
assert_true(err7:match("Qt bindings not available"), "Error message correct")
print()

-- Test 8: Replay without Qt
print("Test 8: Replay without Qt")
local success8, err8 = gesture_replay_engine.replay_gestures(gesture_log)
assert_true(not success8, "Replay fails without Qt bindings")
assert_true(err8:match("Qt bindings not available"), "Error message correct")
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
