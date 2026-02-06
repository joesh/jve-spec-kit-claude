--- Test: frame_utils.normalize_rate asserts on nil and errors on unknown type
-- Regression: returned default_frame_rate (30fps) for nil and unrecognized types
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local frame_utils = require("core.frame_utils")

-- Test 1: nil rate should assert
local ok1, err1 = pcall(function()
    frame_utils.normalize_rate(nil)
end)
check("nil rate asserts", not ok1)
check("error mentions rate", err1 and tostring(err1):find("rate") ~= nil)

-- Test 2: string rate should error (unrecognized type)
local ok2, err2 = pcall(function()
    frame_utils.normalize_rate("24fps")
end)
check("string rate errors", not ok2)

-- Test 3: boolean rate should error
local ok3, err3 = pcall(function()
    frame_utils.normalize_rate(true)
end)
check("boolean rate errors", not ok3)

-- Test 4: valid table rate still works
local r = frame_utils.normalize_rate({ fps_numerator = 24, fps_denominator = 1 })
check("table rate works", r.fps_numerator == 24)

-- Test 5: valid number rate still works
local r2 = frame_utils.normalize_rate(30)
check("number rate works", r2.fps_numerator == 30)

if failed > 0 then
    print(string.format("❌ test_normalize_rate_no_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_normalize_rate_no_fallback.lua passed (%d assertions)", passed))
