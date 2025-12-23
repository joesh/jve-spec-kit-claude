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
-- Size: ~113 LOC
-- Volatility: unknown
--
-- @file test_runner_mocked.lua
-- Original intent (unreviewed):
-- test_runner_mocked.lua
-- Mocked test runner for fast regression testing without Qt/GUI
local json_test_loader = require("bug_reporter.json_test_loader")
local differential_validator = require("bug_reporter.differential_validator")

local TestRunnerMocked = {}

-- Run a single test
-- @param test_path: Path to JSON test file
-- @return: Test result object
function TestRunnerMocked.run_test(test_path)
    local result = {
        test_path = test_path,
        success = false,
        load_time_ms = 0,
        execution_time_ms = 0,
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

    -- 2. Execute commands (mocked - replay the original commands)
    local exec_start = os.clock()
    local replay_capture = TestRunnerMocked.execute_commands_mocked(test)
    result.execution_time_ms = (os.clock() - exec_start) * 1000

    if not replay_capture then
        result.error = "Command execution failed"
        result.total_time_ms = (os.clock() - start_time) * 1000
        return result
    end

    -- 3. Validate replay against original
    local valid_start = os.clock()
    local validation_results = differential_validator.validate(test, replay_capture)
    result.validation_time_ms = (os.clock() - valid_start) * 1000

    result.validation_results = validation_results
    result.success = validation_results.overall_success

    result.total_time_ms = (os.clock() - start_time) * 1000

    return result
end

-- Execute commands in mocked environment
-- For now, this just replays the original commands (perfect replay)
-- When integrated with real command_manager, this will actually execute
function TestRunnerMocked.execute_commands_mocked(test)
    -- For Phase 4, we simulate perfect replay
    -- In real integration, this would:
    --   1. Set up mock database from test.setup
    --   2. Execute each command from test.command_log
    --   3. Capture results
    --   4. Return replay capture

    -- Simulated replay: copy original data (perfect match)
    return {
        command_log = test.command_log,
        log_output = test.log_output
    }
end

-- Run all tests in a directory
-- @param dir_path: Path to directory containing test JSON files
-- @return: Summary results
function TestRunnerMocked.run_directory(dir_path)
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
        local result = TestRunnerMocked.run_test(test._source_file)
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
function TestRunnerMocked.print_result(result)
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

-- Print summary report
function TestRunnerMocked.print_summary(summary)
    print("\n" .. string.rep("=", 60))
    print("Test Run Summary")
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

return TestRunnerMocked
