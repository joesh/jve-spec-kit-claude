-- Regression: AOP.OPEN rejects invalid config (rule 2.13: no silent
-- defaults). Pre-fix, the binding accepted missing args via
-- luaL_optinteger (defaulting to 48000/2/100) AND the C++ AudioOutput::Open
-- replaced any non-positive config field with the same hardcoded numbers.
-- A caller passing 0 or nil silently got a 48k stereo 100ms device.
--
-- Post-fix:
--   * Missing argument → luaL_checkinteger raises a Lua error mentioning
--     the argument index.
--   * Zero/negative argument → JVE_ASSERT in AudioOutput::Open fires with
--     the AopConfig field name.
--
-- Run via: ./build/bin/jve --test tests/test_aop_open_rejects_invalid_config.lua
require("test_env")

if not (qt_constants and qt_constants.AOP) then
    -- Qt bindings only exist inside the JVEEditor host process.
    print("✅ test_aop_open_rejects_invalid_config.lua skipped (needs Qt bindings)")
    return
end

local AOP = qt_constants.AOP
assert(AOP.OPEN and AOP.CLOSE,
    "AOP.OPEN/CLOSE must be exposed")

local function expect_error(label, fn, expected_substr)
    local ok, err = pcall(fn)
    assert(not ok, string.format(
        "%s: AOP.OPEN was expected to fail but returned successfully", label))
    assert(tostring(err):find(expected_substr, 1, true), string.format(
        "%s: error must mention %q for actionable diagnosis; got %s",
        label, expected_substr, tostring(err)))
end

-- ----------------------------------------------------------------------
-- Test 1: a valid open succeeds (sanity — fix did not break the happy path)
-- ----------------------------------------------------------------------
local aop, err = AOP.OPEN(48000, 2, 100)
assert(aop, "AOP.OPEN(48000, 2, 100) must succeed: " .. tostring(err))
AOP.CLOSE(aop)

-- ----------------------------------------------------------------------
-- Test 2: missing arguments are rejected by luaL_checkinteger.
-- ----------------------------------------------------------------------
expect_error("missing channels (#2)",
    function() AOP.OPEN(48000) end, "argument")
expect_error("missing buffer_ms (#3)",
    function() AOP.OPEN(48000, 2) end, "argument")

-- ----------------------------------------------------------------------
-- Test 3: zero / negative config is rejected by AudioOutput::Open.
-- The assertion message must name the AopConfig field so the bug is
-- traceable to the call site.
-- ----------------------------------------------------------------------
expect_error("zero sample_rate",
    function() AOP.OPEN(0, 2, 100) end, "sample_rate")
expect_error("negative sample_rate",
    function() AOP.OPEN(-48000, 2, 100) end, "sample_rate")
expect_error("zero channels",
    function() AOP.OPEN(48000, 0, 100) end, "channels")
expect_error("zero target_buffer_ms",
    function() AOP.OPEN(48000, 2, 0) end, "target_buffer_ms")

print("✅ test_aop_open_rejects_invalid_config.lua passed")
