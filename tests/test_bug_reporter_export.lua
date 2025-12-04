#!/usr/bin/env lua
-- test_bug_reporter_export.lua
-- Test Phase 2 export functionality

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

local function assert_file_exists(path, message)
    test_count = test_count + 1
    local file = io.open(path, "r")
    if file then
        file:close()
        pass_count = pass_count + 1
        print("✓ " .. message)
    else
        print("✗ " .. message)
        print("  File not found: " .. path)
    end
end

print("=== Testing Bug Reporter Export (Phase 2) ===\n")

-- Test 1: Initialize and populate capture_manager
print("Test 1: Populate capture data")
capture_manager:init()

-- Add sample gestures
for i = 1, 10 do
    capture_manager:log_gesture({
        type = "mouse_move",
        screen_x = i * 10,
        screen_y = i * 10,
        window_x = i * 10,
        window_y = i * 10,
        modifiers = {}
    })
end

-- Add sample commands
for i = 1, 5 do
    capture_manager:log_command(
        "TestCommand" .. i,
        {param1 = "value" .. i, param2 = i * 100},
        {success = true},
        "g" .. (i * 2)
    )
end

-- Add sample log messages
capture_manager:log_message("info", "Test info message 1")
capture_manager:log_message("warning", "Test warning message")
capture_manager:log_message("error", "Test error message")

assert_equal(#capture_manager.gesture_ring_buffer, 10, "10 gestures captured")
assert_equal(#capture_manager.command_ring_buffer, 5, "5 commands captured")
assert_equal(#capture_manager.log_ring_buffer, 3, "3 log messages captured")
print()

-- Test 2: Export to JSON (without screenshots since we don't have Qt)
print("Test 2: Export capture to JSON")

local metadata = {
    capture_type = "test",
    test_name = "Test export functionality",
    category = "test",
    tags = {"test", "export"},
    user_description = "Testing JSON export",
    output_dir = "/tmp/jve_test_captures"
}

local json_path, err = capture_manager:export_capture(metadata)

if not json_path then
    print("✗ Export failed: " .. (err or "unknown error"))
else
    assert_true(json_path ~= nil, "Export succeeded")
    assert_file_exists(json_path, "JSON file created")
    print("  JSON path: " .. json_path)
end
print()

-- Test 3: Verify JSON content
print("Test 3: Verify JSON content")

if json_path then
    local file = io.open(json_path, "r")
    if file then
        local content = file:read("*a")
        file:close()

        -- Parse JSON
        local dkjson = require("dkjson")
        local data, pos, err = dkjson.decode(content)

        if data then
            assert_equal(data.test_format_version, "1.0", "Format version is 1.0")
            assert_equal(data.capture_metadata.capture_type, "test", "Capture type is 'test'")
            assert_equal(data.capture_metadata.user_description, "Testing JSON export", "User description preserved")
            assert_equal(#data.gesture_log, 10, "10 gestures in JSON")
            assert_equal(#data.command_log, 5, "5 commands in JSON")
            assert_equal(#data.log_output, 3, "3 log messages in JSON")

            -- Verify gesture structure
            local first_gesture = data.gesture_log[1]
            assert_equal(first_gesture.type, "mouse_move", "First gesture type correct")
            assert_equal(first_gesture.screen_x, 10, "First gesture x coord correct")

            -- Verify command structure
            local first_command = data.command_log[1]
            assert_equal(first_command.command, "TestCommand1", "First command name correct")
            assert_equal(first_command.triggered_by_gesture, "g2", "Command linked to gesture")

            -- Verify log structure
            local first_log = data.log_output[1]
            assert_equal(first_log.level, "info", "First log level correct")
            assert_equal(first_log.message, "Test info message 1", "First log message correct")
        else
            print("✗ Failed to parse JSON: " .. (err or "unknown"))
        end
    else
        print("✗ Failed to read JSON file")
    end
end
print()

-- Test 4: Test automatic error capture
print("Test 4: Automatic error capture")

-- Populate some more data
capture_manager:clear_buffers()
capture_manager:log_gesture({type = "mouse_press", screen_x = 100, screen_y = 200, modifiers = {}})
capture_manager:log_command("FailedCommand", {}, {success = false, error = "Something broke"})
capture_manager:log_message("error", "Critical error occurred")

-- Use the init module's capture_on_error function
local bug_reporter = require("bug_reporter.init")
local error_json = bug_reporter.capture_on_error("Test error", "stack trace here")

if error_json then
    assert_true(error_json ~= nil, "Error capture succeeded")
    assert_file_exists(error_json, "Error JSON file created")
    print("  Error JSON: " .. error_json)
else
    print("✗ Error capture failed")
end
print()

-- Test 5: Test manual capture
print("Test 5: Manual capture")

capture_manager:clear_buffers()
capture_manager:log_gesture({type = "key_press", key = "A", modifiers = {"Shift"}})
capture_manager:log_command("ManualTestCommand", {test = true}, {success = true})

local manual_json = bug_reporter.capture_manual(
    "User noticed clip overlap",
    "Clips should maintain gap"
)

if manual_json then
    assert_true(manual_json ~= nil, "Manual capture succeeded")
    assert_file_exists(manual_json, "Manual JSON file created")
    print("  Manual JSON: " .. manual_json)

    -- Verify it has user description
    local file = io.open(manual_json, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local dkjson = require("dkjson")
        local data = dkjson.decode(content)
        if data then
            assert_equal(data.capture_metadata.user_description, "User noticed clip overlap", "User description in manual capture")
            assert_equal(data.capture_metadata.capture_type, "user_submitted", "Capture type is user_submitted")
        end
    end
else
    print("✗ Manual capture failed")
end
print()

-- Clean up test files (optional)
print("Test captures saved to: /tmp/jve_test_captures/")

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
