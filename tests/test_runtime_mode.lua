#!/usr/bin/env luajit
-- Regression: runtime_mode.assert_production — silent in test, loud
-- in production. Lets NSF-compliant "DB must be open" guards assert
-- in production while staying runnable under pure-Lua unit tests that
-- don't stand up a DB.
--
-- Domain behavior (no implementation tracing):
--   * is_test() returns true under the test harness (the flag
--     _G.__JVE_TEST_HARNESS_RUNNING is set by tests/test_harness.lua).
--   * is_test() returns true when JVE_TEST_MODE env var is "1" or
--     "true" (the integration --test mode sets this in main.cpp).
--   * assert_production(false, msg) is a no-op in test mode.
--   * assert_production(false, msg) raises in production mode.
--   * assert_production(true, msg) is always a no-op.

require('test_env')

local runtime_mode = require('core.runtime_mode')

print("=== runtime_mode contract ===")

-- ----------------------------------------------------------------------
-- 1. Under the harness, is_test() is true.
-- ----------------------------------------------------------------------
assert(runtime_mode.is_test() == true,
    "harness sets __JVE_TEST_HARNESS_RUNNING so is_test() must be true")
print("  OK: harness → is_test() true")

-- ----------------------------------------------------------------------
-- 2. assert_production: false condition + test mode → no-op.
-- ----------------------------------------------------------------------
local ok = pcall(runtime_mode.assert_production, false, "should be silent in test")
assert(ok, "assert_production(false, ...) must NOT raise in test mode")
print("  OK: false + test mode → silent")

-- ----------------------------------------------------------------------
-- 3. Simulate production: clear both signals, confirm raise.
-- pcall wraps the assertions so that a failure can't leave the harness
-- flag dangling nil — subsequent tests would see is_test()==false and
-- start raising unexpectedly.
-- ----------------------------------------------------------------------
local saved_flag = rawget(_G, "__JVE_TEST_HARNESS_RUNNING")
local saved_env  = os.getenv("JVE_TEST_MODE")
rawset(_G, "__JVE_TEST_HARNESS_RUNNING", nil)
local body_ok, body_err = pcall(function()
    if saved_env == "1" or saved_env == "true" then
        print("  SKIP: JVE_TEST_MODE env set externally — can't simulate production")
        return
    end
    assert(runtime_mode.is_test() == false,
        "without harness flag and without JVE_TEST_MODE env, is_test() must be false")
    local raised, err = pcall(runtime_mode.assert_production, false,
        "production assert message with context")
    assert(not raised,
        "assert_production(false, ...) MUST raise in production mode")
    assert(tostring(err):find("production assert message"),
        "raised error must include the caller's message: " .. tostring(err))
    print("  OK: false + production mode → raises with actionable message")
end)
rawset(_G, "__JVE_TEST_HARNESS_RUNNING", saved_flag)
assert(body_ok, "production simulation block failed: " .. tostring(body_err))

-- ----------------------------------------------------------------------
-- 4. assert_production(true, ...) never raises regardless of mode.
-- ----------------------------------------------------------------------
local ok2 = pcall(runtime_mode.assert_production, true, "should never fire")
assert(ok2, "assert_production(true, ...) must be a no-op")
-- "Truthy" values also pass — matches Lua's standard assert semantics.
local ok3 = pcall(runtime_mode.assert_production, 42, "truthy")
local ok4 = pcall(runtime_mode.assert_production, "x", "truthy")
assert(ok3 and ok4, "assert_production must treat any truthy value as pass")
print("  OK: truthy conditions always pass")

print("✅ test_runtime_mode.lua passed")
