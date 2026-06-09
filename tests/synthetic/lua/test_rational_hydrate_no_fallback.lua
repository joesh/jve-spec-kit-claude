--- Test: Rational.hydrate asserts when fps cannot be determined
-- Regression: silently used 30fps when table had .frames but no fps info
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local Rational = require("core.rational")

-- Test 1: Table with .frames but no fps_numerator and no fps_num arg → must error
local ok1, err1 = pcall(function()
    Rational.hydrate({ frames = 5 })
end)
check("bare table with frames but no fps asserts", not ok1)
check("error mentions fps", err1 and tostring(err1):find("fps") ~= nil)

-- Test 2: Bare number with no fps_num arg → must error
local ok2 = pcall(function()
    Rational.hydrate(50)
end)
check("bare number with no fps asserts", not ok2)

-- Test 3: Table with .frames AND .fps_numerator → still works
local r1 = Rational.hydrate({ frames = 42, fps_numerator = 30, fps_denominator = 1 })
check("table with fps works", r1 ~= nil)
check("table fps_num = 30", r1.fps_numerator == 30)
check("table frames = 42", r1.frames == 42)

-- Test 4: Table with .frames, no .fps_numerator, but fps_num arg provided → works
local r2 = Rational.hydrate({ frames = 5 }, 60, 1)
check("table with arg fps works", r2 ~= nil)
check("arg fps_num = 60", r2.fps_numerator == 60)

-- Test 5: Number with fps_num arg → works
local r3 = Rational.hydrate(100, 24, 1)
check("number with fps works", r3 ~= nil)
check("number fps = 24", r3.fps_numerator == 24)

-- Test 6: Already a Rational → pass through
local existing = Rational.new(10, 24, 1)
local r4 = Rational.hydrate(existing)
check("existing Rational passes through", r4 == existing)

-- Test 7: nil → returns nil (valid)
check("nil returns nil", Rational.hydrate(nil) == nil)

-- Test 8: Table with partial fps (numerator only, no den) → uses 1 for den
local r5 = Rational.hydrate({ frames = 10, fps_numerator = 48 })
check("partial fps: num=48", r5.fps_numerator == 48)
check("partial fps: den defaults 1", r5.fps_denominator == 1)

if failed > 0 then
    print(string.format("❌ test_rational_hydrate_no_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_rational_hydrate_no_fallback.lua passed (%d assertions)", passed))
