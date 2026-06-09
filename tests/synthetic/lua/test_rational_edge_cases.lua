require("test_env")

local Rational = require("core.rational")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

print("\n=== Rational Edge Cases Tests (T11) ===")

-- ============================================================
-- Division by number
-- ============================================================
print("\n--- division by number ---")
do
    local r = Rational.new(100, 24)
    local result = r / 2
    check("div by 2", result.frames == 50)
    check("div preserves rate", result.fps_numerator == 24)

    -- Rounding (half-up)
    local r2 = Rational.new(7, 24)
    local d2 = r2 / 2  -- 7/2 = 3.5 → floor(3.5 + 0.5) = 4
    check("div rounds half-up", d2.frames == 4)

    local r3 = Rational.new(5, 24)
    local d3 = r3 / 3  -- 5/3 = 1.666 → floor(1.666 + 0.5) = 2
    check("div rounds 5/3 → 2", d3.frames == 2)

    expect_error("div by zero number", function()
        local _ = r / 0
    end, "division by zero")
end

-- ============================================================
-- Division by Rational (duration ratio)
-- ============================================================
print("\n--- division by Rational ---")
do
    -- Same rate: ratio of frame counts (adjusted by rates, but same rate cancels)
    local a = Rational.new(100, 24)
    local b = Rational.new(50, 24)
    local ratio = a / b
    check("same-rate ratio", ratio == 2.0)

    -- Different rates: adjusts for duration
    -- 48 frames @ 24fps = 2s; 60 frames @ 30fps = 2s → ratio = 1
    local c = Rational.new(48, 24)
    local d = Rational.new(60, 30)
    local ratio2 = c / d
    check("cross-rate ratio", math.abs(ratio2 - 1.0) < 0.0001)

    -- Zero dividend → 0
    local z = Rational.new(0, 24)
    local ratio3 = z / Rational.new(50, 24)
    check("zero dividend → 0", ratio3 == 0)

    -- Zero-duration divisor → error
    expect_error("div by zero-duration Rational", function()
        local _ = Rational.new(100, 24) / Rational.new(0, 24)
    end, "division by zero duration")

    -- Non-Rational lhs → error
    expect_error("div non-Rational lhs", function()
        local _ = 5 / Rational.new(10, 24)
    end, "lhs must be a Rational")

    -- Non-number/Rational rhs → error
    expect_error("div by string", function()
        local _ = Rational.new(10, 24) / "bad"
    end, "rhs must be a number or Rational")
end

-- ============================================================
-- Hydrate edge cases
-- ============================================================
print("\n--- hydrate ---")
do
    -- nil → nil
    check("hydrate nil", Rational.hydrate(nil) == nil)

    -- false → nil
    check("hydrate false", Rational.hydrate(false) == nil)

    -- Already a Rational → same object
    local r = Rational.new(10, 24)
    check("hydrate Rational identity", Rational.hydrate(r) == r)

    -- Plain table with frames
    local h = Rational.hydrate({ frames = 42, fps_numerator = 30, fps_denominator = 1 })
    check("hydrate table", h ~= nil)
    check("hydrate table frames", h.frames == 42)
    check("hydrate table fps_num", h.fps_numerator == 30)
    check("hydrate table fps_den", h.fps_denominator == 1)

    -- Table with partial fps (only numerator)
    local h2 = Rational.hydrate({ frames = 10, fps_numerator = 48 })
    check("hydrate partial fps: num", h2.fps_numerator == 48)
    check("hydrate partial fps: den defaults 1", h2.fps_denominator == 1)

    -- Table with no fps → must assert (no silent fallback)
    local ok_h3, err_h3 = pcall(function() Rational.hydrate({ frames = 5 }) end)
    check("hydrate no fps asserts", not ok_h3)
    check("hydrate no fps error mentions fps", err_h3 and tostring(err_h3):find("fps") ~= nil)

    -- Table with no fps but caller provides defaults
    local h4 = Rational.hydrate({ frames = 5 }, 60, 1)
    check("hydrate caller default fps", h4.fps_numerator == 60)

    -- Empty table (no .frames) → nil
    check("hydrate empty table", Rational.hydrate({}) == nil)

    -- Number → treated as frames
    local h5 = Rational.hydrate(100, 24, 1)
    check("hydrate number", h5.frames == 100)
    check("hydrate number fps", h5.fps_numerator == 24)

    -- Number no fps → must assert (no silent fallback)
    local ok_h6, err_h6 = pcall(function() Rational.hydrate(50) end)
    check("hydrate number no fps asserts", not ok_h6)
    check("hydrate number no fps error mentions fps", err_h6 and tostring(err_h6):find("fps") ~= nil)

    -- String → nil
    check("hydrate string", Rational.hydrate("123") == nil)

    -- Boolean true → nil (only false is handled by `not val`)
    -- Actually `not true` is false so it falls through. true is truthy.
    -- type(true) is "boolean", not "table" or "number", so returns nil
    check("hydrate true", Rational.hydrate(true) == nil)

    -- Table with frames = 0 → valid
    local h7 = Rational.hydrate({ frames = 0, fps_numerator = 24, fps_denominator = 1 })
    check("hydrate zero frames", h7 ~= nil and h7.frames == 0)

    -- Table with negative frames → valid
    local h8 = Rational.hydrate({ frames = -10, fps_numerator = 24, fps_denominator = 1 })
    check("hydrate negative frames", h8 ~= nil and h8.frames == -10)
end

-- ============================================================
-- Negative frame arithmetic
-- ============================================================
print("\n--- negative frame arithmetic ---")
do
    local neg = Rational.new(-10, 24)
    local pos = Rational.new(30, 24)

    local sum = neg + pos
    check("neg + pos", sum.frames == 20)

    local diff = pos - neg
    check("pos - neg", diff.frames == 40)

    local neg2 = neg + neg
    check("neg + neg", neg2.frames == -20)

    -- Subtraction resulting in negative
    local sub = Rational.new(5, 24) - Rational.new(10, 24)
    check("sub goes negative", sub.frames == -5)
end

-- ============================================================
-- Unary negation
-- ============================================================
print("\n--- unary negation ---")
do
    local r = Rational.new(42, 24)
    local neg = -r
    check("unary neg frames", neg.frames == -42)
    check("unary neg rate preserved", neg.fps_numerator == 24)

    -- Double negation
    local pos = -neg
    check("double negation", pos.frames == 42)

    -- Negate zero
    local z = -Rational.new(0, 24)
    check("negate zero", z.frames == 0)
end

-- ============================================================
-- Multiply
-- ============================================================
print("\n--- multiply ---")
do
    local r = Rational.new(10, 24)

    -- Rational * number
    local m1 = r * 3
    check("Rational * 3", m1.frames == 30)

    -- number * Rational
    local m2 = 3 * r
    check("3 * Rational", m2.frames == 30)

    -- Fractional multiply with rounding
    local m3 = Rational.new(10, 24) * 1.5  -- 10 * 1.5 = 15
    check("mul fractional exact", m3.frames == 15)

    local m4 = Rational.new(7, 24) * 1.5  -- 7 * 1.5 = 10.5 → floor(10.5 + 0.5) = 11
    check("mul fractional rounds", m4.frames == 11)

    -- Multiply by zero → 0 frames
    local m5 = r * 0
    check("mul by zero", m5.frames == 0)

    -- Two Rationals → error
    expect_error("mul two Rationals", function()
        local _ = r * Rational.new(5, 24)
    end, "operands must be Rational and number")
end

-- ============================================================
-- Cross-rate comparison
-- ============================================================
print("\n--- cross-rate comparison ---")
do
    -- Equal durations at different rates
    -- 24 frames @ 24fps = 1s; 30 frames @ 30fps = 1s
    local a = Rational.new(24, 24)
    local b = Rational.new(30, 30)
    check("cross-rate eq: 1s == 1s", a == b)

    -- Unequal durations
    -- 24 frames @ 24fps = 1s; 29 frames @ 30fps = 0.967s
    local c = Rational.new(29, 30)
    check("cross-rate neq", a ~= c)

    -- Less-than cross-rate
    -- 23 frames @ 24fps < 30 frames @ 30fps → 23/24 < 30/30 → 0.958 < 1.0
    local d = Rational.new(23, 24)
    check("cross-rate lt", d < b)
    check("cross-rate not lt (equal)", a >= b)
    check("cross-rate gt via lt", b > d)

    -- NTSC cross-rate equality
    -- 30000/1001 fps: 30000 frames = 30000 * 1001 / 30000 = 1001s
    -- 24/1 fps: 24024 frames = 24024 / 24 = 1001s
    local ntsc = Rational.new(30000, 30000, 1001)
    local film = Rational.new(24024, 24, 1)
    check("NTSC vs film equality", ntsc == film)

    -- NOTE: Lua 5.1/LuaJIT does NOT invoke __eq or __lt metamethods for
    -- mixed number/table operands. The number coercion paths in rational.lua
    -- (lines 251-254, 278-281) are unreachable via operators in LuaJIT.
    -- These paths would only work in Lua 5.3+ or if both sides are Rational.
end

-- ============================================================
-- max()
-- ============================================================
print("\n--- max ---")
do
    local a = Rational.new(10, 24)
    local b = Rational.new(20, 24)
    check("max same rate", Rational.max(a, b) == b)
    check("max same rate reverse", Rational.max(b, a) == b)
    check("max equal", Rational.max(a, a) == a)

    -- Cross-rate: 48 frames @ 48fps = 1s; 30 frames @ 24fps = 1.25s
    local c = Rational.new(48, 48)
    local d = Rational.new(30, 24)
    local m = Rational.max(c, d)
    -- d (1.25s) > c (1s), but max rescales d to c's rate
    -- d rescaled to 48fps: 30 * 48 / 24 = 60 frames
    -- 60 > 48 → returns d (rescaled)
    check("max cross-rate returns larger duration", m.frames == 60)
    check("max cross-rate uses r1 rate", m.fps_numerator == 48)

    expect_error("max non-Rational", function()
        Rational.max(a, 42)
    end, "operands must be Rational")
end

-- ============================================================
-- from_seconds
-- ============================================================
print("\n--- from_seconds ---")
do
    local r = Rational.from_seconds(1.0, 24)
    check("from_seconds 1s @ 24", r.frames == 24)

    local r2 = Rational.from_seconds(0.5, 30)
    check("from_seconds 0.5s @ 30", r2.frames == 15)

    local r3 = Rational.from_seconds(0, 24)
    check("from_seconds 0s", r3.frames == 0)

    -- Rounding
    local r4 = Rational.from_seconds(1.0 / 30, 24)
    -- 1/30 * 24 = 0.8 → floor(0.8 + 0.5) = 1
    check("from_seconds rounding", r4.frames == 1)

    -- NTSC
    local r5 = Rational.from_seconds(1.0, 30000, 1001)
    -- 1.0 * 30000/1001 = 29.97 → floor(29.97 + 0.5) = 30
    check("from_seconds NTSC 1s", r5.frames == 30)

    expect_error("from_seconds non-number", function()
        Rational.from_seconds("1.0", 24)
    end, "seconds must be a number")
end

-- ============================================================
-- to_seconds / to_milliseconds
-- ============================================================
print("\n--- to_seconds / to_milliseconds ---")
do
    local r = Rational.new(24, 24)
    check("to_seconds 1s", r:to_seconds() == 1.0)
    check("to_milliseconds 1s", r:to_milliseconds() == 1000.0)

    local r2 = Rational.new(0, 24)
    check("to_seconds 0", r2:to_seconds() == 0)
    check("to_milliseconds 0", r2:to_milliseconds() == 0)

    -- NTSC
    local r3 = Rational.new(30000, 30000, 1001)
    -- 30000 / (30000/1001) = 30000 * 1001 / 30000 = 1001
    check("to_seconds NTSC 30000 frames", math.abs(r3:to_seconds() - 1001.0) < 0.001)

    -- Negative frames
    local r4 = Rational.new(-24, 24)
    check("to_seconds negative", r4:to_seconds() == -1.0)
    check("to_milliseconds negative", r4:to_milliseconds() == -1000.0)
end

-- ============================================================
-- tostring edge cases
-- ============================================================
print("\n--- tostring ---")
do
    check("tostring den=1 omits /1", tostring(Rational.new(10, 24)) == "Rational(10 @ 24/1)")
    check("tostring NTSC", tostring(Rational.new(100, 30000, 1001)) == "Rational(100 @ 30000/1001)")
    check("tostring negative", tostring(Rational.new(-5, 24)) == "Rational(-5 @ 24/1)")
    check("tostring zero", tostring(Rational.new(0, 24)) == "Rational(0 @ 24/1)")
end

-- ============================================================
-- rescale_floor / rescale_ceil
-- ============================================================
print("\n--- rescale_floor / rescale_ceil ---")
do
    -- 1 frame @ 30fps = 0.0333s → @ 24fps = 0.8 frames
    local r = Rational.new(1, 30)
    check("rescale_floor rounds down", r:rescale_floor(24).frames == 0)
    check("rescale_ceil rounds up", r:rescale_ceil(24).frames == 1)
    check("rescale rounds half-up", r:rescale(24).frames == 1)

    -- 10 frames @ 30 → 24: 8.0 exact
    local r2 = Rational.new(10, 30)
    check("rescale_floor exact", r2:rescale_floor(24).frames == 8)
    check("rescale_ceil exact", r2:rescale_ceil(24).frames == 8)

    -- Identity rescale returns new object
    local r3 = Rational.new(10, 24)
    local r3r = r3:rescale(24)
    check("rescale identity frames", r3r.frames == 10)
    check("rescale identity new object", not rawequal(r3r, r3))
end

-- ============================================================
-- metatable exposed
-- ============================================================
print("\n--- metatable ---")
do
    check("metatable exposed", Rational.metatable ~= nil)
    local r = Rational.new(1, 24)
    check("metatable matches", getmetatable(r) == Rational.metatable)
end

-- ============================================================
-- Summary
-- ============================================================
print("")
print(string.format("Passed: %d  Failed: %d  Total: %d", pass_count, fail_count, pass_count + fail_count))
if fail_count > 0 then
    print("SOME TESTS FAILED")
    os.exit(1)
else
    print("✅ test_rational_edge_cases.lua passed")
end
