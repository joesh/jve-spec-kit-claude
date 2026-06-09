--- Test: format_duration asserts when frame_rate is nil
-- Regression: silently fell back to default_frame_rate (30fps)
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local frame_utils = require("core.frame_utils")

-- Test 1: nil frame_rate with a Rational duration should assert
local dur = 100
local ok1, err1 = pcall(function()
    frame_utils.format_duration(dur, nil)
end)
check("nil frame_rate asserts", not ok1)
check("error mentions frame_rate", err1 and tostring(err1):find("frame_rate") ~= nil)

-- Test 2: nil duration returns "--:--" (valid)
check("nil duration returns placeholder", frame_utils.format_duration(nil, nil) == "--:--")

-- Test 3: valid frame_rate still works
local result = frame_utils.format_duration(dur, { fps_numerator = 24, fps_denominator = 1 })
check("valid frame_rate works", result ~= nil and result ~= "--:--")

if failed > 0 then
    print(string.format("❌ test_format_duration_no_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_format_duration_no_fallback.lua passed (%d assertions)", passed))
