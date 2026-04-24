--- Runtime-mode detection for NSF assertions.
---
--- Silent-skip guards like `if not get_database().has_connection() then return end`
--- accommodate tests that don't stand up a DB. In production those guards
--- mask real bugs — a missing DB connection during project-open signal
--- delivery is not a state the app should ever reach. is_test() lets
--- the guards upgrade to asserts in production while staying silent in
--- test contexts.
---
--- Test contexts detected:
---   * Lua unit tests: `test_harness.lua` sets `_G.__JVE_TEST_HARNESS_RUNNING`.
---   * Integration `--test` mode: `main.cpp` sets env `JVE_TEST_MODE=1`
---     before invoking the Lua script.
---
--- @file runtime_mode.lua

local M = {}

--- Return true when the current process is executing a test (unit or
--- integration), false in the normal GUI flow.
function M.is_test()
    if rawget(_G, "__JVE_TEST_HARNESS_RUNNING") then return true end
    local env = os.getenv("JVE_TEST_MODE")
    return env == "1" or env == "true"
end

--- Assert that `cond` holds, but only when NOT in test mode. Test
--- contexts silently skip, so pure-logic tests that don't stand up the
--- full app state stay runnable. Production crashes loudly with the
--- message so the bug surfaces.
--- @param cond any  condition to check (any truthy value passes)
--- @param msg string actionable error message (include function name + IDs)
function M.assert_production(cond, msg)
    if cond then return end
    if M.is_test() then return end
    error(msg, 2)
end

return M
