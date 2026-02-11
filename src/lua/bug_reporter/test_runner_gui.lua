--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~155 LOC
-- Volatility: unknown
--
-- @file test_runner_gui.lua
-- Original intent (unreviewed):
-- test_runner_gui.lua
-- GUI test runner - replays gestures in actual JVE application for pixel-perfect testing
local json_test_loader = require("bug_reporter.json_test_loader")
local differential_validator = require("bug_reporter.differential_validator")
local gesture_replay_engine = require("bug_reporter.gesture_replay_engine")

local TestRunnerGUI = {}

-- State for capturing commands during replay
local replay_state = {
    enabled = false,
    command_log = {},
    log_output = {}
}

-- Hook into command_manager to capture commands during replay
-- This should be called before replay starts
function TestRunnerGUI.install_command_capture_hook()
    -- Requires access to command_manager - will be set up during integration
    -- For now, this is a placeholder
    replay_state.enabled = true
    replay_state.command_log = {}
    replay_state.log_output = {}
end

-- Unhook command capture
function TestRunnerGUI.uninstall_command_capture_hook()
    replay_state.enabled = false
end

-- Capture a command (called from command_manager during replay)
function TestRunnerGUI.capture_command(command_name, parameters, result, gesture_id)
    if not replay_state.enabled then
        return
    end

    table.insert(replay_state.command_log, {
        command = command_name,
        parameters = parameters,
        result = result,
        triggered_by_gesture = gesture_id
    })
end

-- Capture a log message (called from logging system during replay)
function TestRunnerGUI.capture_log_message(level, message)
    if not replay_state.enabled then
        return
    end

    table.insert(replay_state.log_output, {
        level = level,
        message = message
    })
end

-- Run a single GUI test
-- @param test_path: Path to JSON test file
-- @param options: Optional parameters (speed_multiplier, reset_state)
-- @return: Test result object
function TestRunnerGUI.run_test(test_path, options)
    options = options or {}
    local speed_multiplier = options.speed_multiplier or 1.0
    local reset_state = options.reset_state ~= false  -- Default true

    local result = {
        test_path = test_path,
        success = false,
        load_time_ms = 0,
        replay_time_ms = 0,
        validation_time_ms = 0,
        total_time_ms = 0,
        error = nil,
        validation_results = nil
    }

    local start_time = os.clock()

    -- 1. Load test
    local load_start = os.clock()
    local test, err = json_test_loader.load(test_path)
    result.load_time_ms = (os.clock() - load_start) * 1000

    if not test then
        result.error = "Failed to load test: " .. err
        result.total_time_ms = (os.clock() - start_time) * 1000
        return result
    end

    result.test_id = test.test_id
    result.test_name = test.test_name

    -- 2. Reset application state if requested
    if reset_state and test.database_snapshot then  -- luacheck: ignore 542 (empty branch - TODO: load database snapshot)
        -- requires database integration
    end

    -- 3. Install command capture hook
    TestRunnerGUI.install_command_capture_hook()

    -- 4. Replay gestures
    local replay_start = os.clock()
    local replay_success, replay_err = gesture_replay_engine.replay_gestures(
        test.gesture_log,
        {speed_multiplier = speed_multiplier}
    )
    result.replay_time_ms = (os.clock() - replay_start) * 1000

    -- 5. Unhook command capture
    TestRunnerGUI.uninstall_command_capture_hook()

    if not replay_success then
        result.error = "Gesture replay failed: " .. (replay_err or "unknown error")
        result.total_time_ms = (os.clock() - start_time) * 1000
        return result
    end

    -- 6. Build replay capture for validation
    local replay_capture = {
        command_log = replay_state.command_log,
        log_output = replay_state.log_output
    }

    -- 7. Validate replay against original
    local valid_start = os.clock()
    local validation_results = differential_validator.validate(test, replay_capture)
    result.validation_time_ms = (os.clock() - valid_start) * 1000

    result.validation_results = validation_results
    result.success = validation_results.overall_success

    result.total_time_ms = (os.clock() - start_time) * 1000

    return result
end

-- Run all tests in a directory
-- @param dir_path: Path to directory containing test JSON files
-- @param options: Optional parameters
-- @return: Summary results
function TestRunnerGUI.run_directory(dir_path, options)
    local summary = {
        total_tests = 0,
        passed = 0,
        failed = 0,
        total_time_ms = 0,
        results = {}
    }

    local start_time = os.clock()

    -- Load all tests
    local tests, err = json_test_loader.load_directory(dir_path)
    if not tests then
        summary.error = err
        return summary
    end

    summary.total_tests = #tests

    -- Run each test
    for _, test in ipairs(tests) do
        local result = TestRunnerGUI.run_test(test._source_file, options)
        table.insert(summary.results, result)

        if result.success then
            summary.passed = summary.passed + 1
        else
            summary.failed = summary.failed + 1
        end
    end

    summary.total_time_ms = (os.clock() - start_time) * 1000

    return summary
end

-- Print test result
function TestRunnerGUI.print_result(result)
    if result.success then
        print(string.format("✓ %s (%.2fms)", result.test_name or result.test_path, result.total_time_ms))
    else
        print(string.format("✗ %s (%.2fms)", result.test_name or result.test_path, result.total_time_ms))
        if result.error then
            print("  Error: " .. result.error)
        end
        if result.validation_results then
            print(differential_validator.generate_diff_report(result.validation_results))
        end
    end
end

-- Print summary report (same as mocked runner)
function TestRunnerGUI.print_summary(summary)
    print("\n" .. string.rep("=", 60))
    print("GUI Test Run Summary")
    print(string.rep("=", 60))
    print(string.format("Total:  %d tests", summary.total_tests))
    print(string.format("Passed: %d tests (%.1f%%)", summary.passed,
        summary.total_tests > 0 and (summary.passed / summary.total_tests * 100) or 0))
    print(string.format("Failed: %d tests (%.1f%%)", summary.failed,
        summary.total_tests > 0 and (summary.failed / summary.total_tests * 100) or 0))
    print(string.format("Time:   %.2f seconds", summary.total_time_ms / 1000))

    if summary.failed > 0 then
        print("\nFailed tests:")
        for _, result in ipairs(summary.results) do
            if not result.success then
                print("  - " .. (result.test_name or result.test_path))
            end
        end
    end

    print(string.rep("=", 60))

    if summary.passed == summary.total_tests then
        print("✓ All tests passed!")
    else
        print("✗ Some tests failed")
    end
end

return TestRunnerGUI
