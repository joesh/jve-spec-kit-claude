#!/usr/bin/env lua
-- test_mocked_runner.lua
-- Test Phase 4 mocked test runner

-- Add src/lua to package path
package.path = package.path .. ";../src/lua/?.lua"

local json_test_loader = require("bug_reporter.json_test_loader")
local differential_validator = require("bug_reporter.differential_validator")
local test_runner_mocked = require("bug_reporter.test_runner_mocked")
local capture_manager = require("bug_reporter.capture_manager")

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

print("=== Testing Mocked Test Runner (Phase 4) ===\n")

-- Test 1: Create a test capture for testing
print("Test 1: Generate test capture")
capture_manager:init()
capture_manager:clear_buffers()

-- Add sample data
for i = 1, 5 do
    capture_manager:log_gesture({type = "mouse_move", screen_x = i * 10, screen_y = i * 10, modifiers = {}})
end

for i = 1, 3 do
    capture_manager:log_command(
        "TestCommand" .. i,
        {param = i},
        {success = true},
        "g" .. i
    )
end

capture_manager:log_message("warning", "Test warning")
capture_manager:log_message("error", "Test error")

local test_path = capture_manager:export_capture({
    capture_type = "test",
    test_name = "Test runner validation",
    category = "test",
    output_dir = "/tmp/jve_runner_test"
})

assert_not_nil(test_path, "Test capture generated")
if test_path then
    print("  Test path: " .. test_path)
end
print()

-- Test 2: JSON test loader
print("Test 2: JSON test loader")
if test_path then
    local test = json_test_loader.load(test_path)
    assert_not_nil(test, "Test loaded successfully")

    if test then
        assert_true(test.test_format_version == "1.0", "Test format version is 1.0")
        assert_true(test.test_name == "Test runner validation", "Test name correct")
        assert_true(#test.gesture_log == 5, "5 gestures loaded")
        assert_true(#test.command_log == 3, "3 commands loaded")
        assert_true(#test.log_output == 2, "2 log messages loaded")

        local summary = json_test_loader.get_summary(test)
        assert_true(summary.gesture_count == 5, "Summary shows 5 gestures")
        assert_true(summary.command_count == 3, "Summary shows 3 commands")
    end
end
print()

-- Test 3: Differential validator - perfect match
print("Test 3: Differential validator (perfect match)")
local original = {
    command_log = {
        {command = "Cmd1", result = {success = true}},
        {command = "Cmd2", result = {success = false, error_message = "Test error"}}
    },
    log_output = {
        {level = "warning", message = "Warning 1"},
        {level = "error", message = "Error 1"}
    }
}

local replay_perfect = {
    command_log = {
        {command = "Cmd1", result = {success = true}},
        {command = "Cmd2", result = {success = false, error_message = "Test error"}}
    },
    log_output = {
        {level = "warning", message = "Warning 1"},
        {level = "error", message = "Error 1"}
    }
}

local result = differential_validator.validate(original, replay_perfect)
assert_true(result.overall_success, "Perfect match validates successfully")
assert_true(result.command_sequence_match, "Command sequence matches")
assert_true(result.command_results_match, "Command results match")
assert_true(result.log_output_match, "Log output matches")
print()

-- Test 4: Differential validator - command mismatch
print("Test 4: Differential validator (command mismatch)")
local replay_wrong_cmd = {
    command_log = {
        {command = "Cmd1", result = {success = true}},
        {command = "WrongCmd", result = {success = false, error_message = "Test error"}}
    },
    log_output = {
        {level = "warning", message = "Warning 1"},
        {level = "error", message = "Error 1"}
    }
}

local result2 = differential_validator.validate(original, replay_wrong_cmd)
assert_true(not result2.overall_success, "Mismatch detected")
assert_true(not result2.command_sequence_match, "Command sequence mismatch detected")
assert_true(#result2.errors > 0, "Error reported")
print()

-- Test 5: Differential validator - result mismatch
print("Test 5: Differential validator (result mismatch)")
local replay_wrong_result = {
    command_log = {
        {command = "Cmd1", result = {success = false}},  -- Should be true
        {command = "Cmd2", result = {success = false, error_message = "Test error"}}
    },
    log_output = {
        {level = "warning", message = "Warning 1"},
        {level = "error", message = "Error 1"}
    }
}

local result3 = differential_validator.validate(original, replay_wrong_result)
assert_true(not result3.overall_success, "Result mismatch detected")
assert_true(not result3.command_results_match, "Command result mismatch detected")
print()

-- Test 6: Run single test with mocked runner
print("Test 6: Run single test")
if test_path then
    local run_result = test_runner_mocked.run_test(test_path)
    assert_true(run_result.success, "Test execution succeeded")
    assert_true(run_result.total_time_ms > 0, "Execution time recorded")

    print(string.format("  Load time:   %.2fms", run_result.load_time_ms))
    print(string.format("  Exec time:   %.2fms", run_result.execution_time_ms))
    print(string.format("  Valid time:  %.2fms", run_result.validation_time_ms))
    print(string.format("  Total time:  %.2fms", run_result.total_time_ms))
end
print()

-- Test 7: Run directory of tests
print("Test 7: Run test directory")
if test_path then
    local summary = test_runner_mocked.run_directory("/tmp/jve_runner_test")
    assert_true(summary.total_tests > 0, "Found tests in directory")
    assert_true(summary.passed > 0, "At least one test passed")
    assert_true(summary.failed == 0, "No tests failed")

    print(string.format("  Total:  %d tests", summary.total_tests))
    print(string.format("  Passed: %d tests", summary.passed))
    print(string.format("  Failed: %d tests", summary.failed))
    print(string.format("  Time:   %.2fms", summary.total_time_ms))
end
print()

-- Clean up
os.execute("rm -rf /tmp/jve_runner_test")

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
