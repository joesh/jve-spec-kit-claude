-- Tests for Rational Time Library
-- Defines the expected behavior for frame-accurate time calculations.

local rational_path = "src/lua/core/rational.lua"
local Rational

-- Helper to load the library safely
local function load_library()
    -- Adjust package path to find the library if running from project root
    if not package.path:find("src/lua/?.lua") then
        package.path = package.path .. ";src/lua/?.lua"
    end
    Rational = require("core.rational")
end

-- Test Runner State
local passed = 0
local failed = 0

local function pass()
    passed = passed + 1
    io.write(".")
end

local function fail(msg)
    failed = failed + 1
    io.write("\nFAIL: " .. msg .. "\n")
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        fail(string.format("%s: Expected '%s', got '%s'", msg, tostring(expected), tostring(actual)))
    else
        pass()
    end
end

local function assert_crash(func, error_fragment, msg)
    local status, err = pcall(func)
    if status == true then
        fail(string.format("%s: Expected crash containing '%s', but succeeded.", msg, error_fragment))
    else
        if not string.find(tostring(err), error_fragment, 1, true) then
            fail(string.format("%s: Crash message '%s' did not contain '%s'", msg, tostring(err), error_fragment))
        else
            pass()
        end
    end
end

-- ============================================================================ 
-- TEST SUITE
-- ============================================================================ 

local function test_construction()
    print("\nTesting Construction...")

    -- 1. Valid Integers
    local t1 = Rational.new(10, 24)
    assert_eq(t1.frames, 10, "t1.frames")
    assert_eq(t1.fps_numerator, 24, "t1.fps_numerator")
    assert_eq(t1.fps_denominator, 1, "t1.fps_denominator (default)")

    -- 2. Valid NTSC
    local t2 = Rational.new(1, 30000, 1001)
    assert_eq(t2.fps_numerator, 30000, "NTSC Num")
    assert_eq(t2.fps_denominator, 1001, "NTSC Den")

    -- 3. Invalid Frames (Float)
    assert_crash(function() Rational.new(10.5, 24) end, "must be integer", "Float frames")

    -- 4. Invalid Rate (Float)
    assert_crash(function() Rational.new(10, 24.5) end, "must be integer", "Float rate num")

    -- 5. Invalid Rate (Zero/Negative)
    assert_crash(function() Rational.new(10, 0) end, "must be positive", "Zero rate num")
    assert_crash(function() Rational.new(10, 24, 0) end, "must be positive", "Zero rate den")
    assert_crash(function() Rational.new(10, -24) end, "must be positive", "Negative rate num")
end

local function test_equality()
    print("\nTesting Equality...")
    local t1 = Rational.new(10, 24)
    local t2 = Rational.new(10, 24)
    local t3 = Rational.new(11, 24)
    local t4 = Rational.new(10, 25)

    -- Lua equality (requires __eq metatable)
    assert_eq(t1 == t2, true, "Identical objects equal")
    assert_eq(t1 == t3, false, "Different frames not equal")
    assert_eq(t1 == t4, false, "Different rates not equal")
end

local function test_rescaling()
    print("\nTesting Rescaling...")

    -- 1. Identity (24 -> 24)
    local t1 = Rational.new(100, 24)
    local t2 = t1:rescale(24, 1)
    assert_eq(t2.frames, 100, "Identity rescale")

    -- 2. Double Rate (24 -> 48)
    local t3 = t1:rescale(48, 1)
    assert_eq(t3.frames, 200, "24 -> 48 fps")

    -- 3. Halve Rate (48 -> 24)
    local t4 = t3:rescale(24, 1)
    assert_eq(t4.frames, 100, "48 -> 24 fps")

    -- 4. Lossy Rounding (30 -> 24)
    -- 1 frame @ 30fps = 1/30 sec.
    -- @ 24fps = 24/30 = 0.8 frames -> rounds to 1.
    local t5 = Rational.new(1, 30)
    local t6 = t5:rescale(24, 1)
    assert_eq(t6.frames, 1, "30 -> 24 rounding (0.8 -> 1)")

    -- 5. Lossy Rounding Down (30 -> 24)
    -- 10 frames @ 30fps = 10/30 = 0.333 sec.
    -- @ 24fps = 8 frames. (0.333 * 24 = 8)
    local t7 = Rational.new(10, 30)
    local t8 = t7:rescale(24, 1)
    assert_eq(t8.frames, 8, "10 frames 30 -> 24 is 8")
end

local function test_arithmetic()
    print("\nTesting Arithmetic...")

    local t1 = Rational.new(10, 24)
    local t2 = Rational.new(5, 24)

    -- 1. Same Rate Add
    local sum = t1 + t2
    assert_eq(sum.frames, 15, "10+5 frames")
    assert_eq(sum.fps_numerator, 24, "Rate preserved")

    -- 2. Different Rate Add (Rescale RHS to LHS)
    -- 10 frames @ 24fps (~0.416s) + 30 frames @ 60fps (0.5s)
    -- 0.5s @ 24fps = 12 frames.
    -- Result: 10 + 12 = 22 frames @ 24fps.
    local t3 = Rational.new(30, 60) -- 0.5s
    local sum_mixed = t1 + t3
    assert_eq(sum_mixed.frames, 22, "Mixed rate add")
    assert_eq(sum_mixed.fps_numerator, 24, "LHS rate preserved")

    -- 3. Subtraction
    local diff = t1 - t2
    assert_eq(diff.frames, 5, "10-5 frames")
end

local function test_ntsc_math()
    print("\nTesting NTSC Math...")

    -- 1 Hour at 29.97 (Drop Frame equivalent rate)
    -- NTSC Rate: 30000 / 1001
    -- 1 Hour = 3600 seconds.
    -- Frames = 3600 * (30000/1001) = 108000000 / 1001 = 107892.107...
    -- Rounded: 107892.

    local one_hour_frames = 107892
    local ntsc_time = Rational.new(one_hour_frames, 30000, 1001)

    -- Convert to seconds (Float check)
    local seconds = ntsc_time:to_seconds()

    -- 107892 frames is actually slightly less than 3600s because 29.97 is slower than 30.
    -- 107892 * 1001 / 30000 = 3599.999...
    -- Wait, Drop Frame timecode *skips* numbers to match wall clock, but the *rate* is constant.
    -- 1 hour of wall clock time contains ~107892 frames.

    -- Let's verify the math library calculation, not the physics.
    -- 107892 / (29.97002997...) = 3599.996

    local expected = 107892 * 1001 / 30000
    assert_eq(math.abs(seconds - expected) < 0.000001, true, "NTSC float conversion accurate")
end

local function test_helpers()
    print("\nTesting Helpers...")
    local t = Rational.new(24, 24) -- 1 second
    assert_eq(t:to_seconds(), 1.0, "to_seconds")
    assert_eq(tostring(t), "Rational(24 @ 24/1)", "tostring format")
end

-- ============================================================================ 
-- MAIN
-- ============================================================================ 

load_library()
test_construction()
test_equality()
test_rescaling()
test_arithmetic()
test_ntsc_math()
test_helpers()

print("\n" .. string.rep("=", 40))
print(string.format("PASSED: %d", passed))
print(string.format("FAILED: %d", failed))

if failed > 0 then
    os.exit(1)
else
    os.exit(0)
end
