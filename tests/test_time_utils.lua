package.path = package.path .. ";src/lua/?.lua;src/lua/?/init.lua;./?.lua;./?/init.lua"

local time_utils = require("core.time_utils")
local Rational = require("core.rational")

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual:   %s", message or "", tostring(expected), tostring(actual)))
    end
end

local function assert_true(condition, message)
    if not condition then
        error(string.format("Assertion failed: %s\nCondition was false.", message or ""))
    end
end

local function assert_close(actual, expected, tolerance, message)
    tolerance = tolerance or 1e-6
    if math.abs(actual - expected) > tolerance then
        error(string.format("Assertion failed: %s\nExpected: %s ±%s\nActual:   %s", message or "", tostring(expected), tostring(tolerance), tostring(actual)))
    end
end

-- Defaults
assert_equal(time_utils.default_audio_rate, 48000, "Default audio rate should be 48k")

-- Frames to samples and back (1 frame at 24fps -> 2000 samples @48k)
local one_frame = time_utils.from_frames(1, 24)
assert_true(getmetatable(one_frame) == Rational.metatable, "from_frames should return a Rational object")

local samples = time_utils.to_samples(one_frame, 48000)
assert_equal(samples, 2000, "1 frame at 24fps should equal 2000 samples at 48k")

local back_to_frames = time_utils.to_frames(time_utils.from_samples(samples, 48000), 24)
assert_equal(back_to_frames, 1, "Sample conversion should round-trip to 1 frame at 24fps")

-- Rational addition with rate conversion
local five_frames_24 = time_utils.from_frames(5, 24)
local two_frames_30 = time_utils.from_frames(2, 30)
local sum = time_utils.add(five_frames_24, two_frames_30)
assert_equal(sum.fps_numerator, 24, "Sum should use lhs fps_numerator")
-- Expected frames = 5 (from lhs) + (2 frames @ 30fps rescaled to 24fps)
-- (2 * 24 / 30) = 1.6, rounded to 2.
-- So, 5 + 2 = 7
-- The Rational class handles rounding in rescale.
local expected_frames_for_sum = 5 + math.floor((2 * 24 / 30) + 0.5)
assert_equal(sum.frames, expected_frames_for_sum, "Cross-rate add should round into target rate")

-- Milliseconds conversion round trip
local ms_rt = time_utils.from_milliseconds(1000, 25) -- 1s @25fps
assert_true(getmetatable(ms_rt) == Rational.metatable, "from_milliseconds should return a Rational object")
assert_equal(ms_rt.fps_numerator, 25, "from_milliseconds should honor provided fps_numerator")
assert_equal(ms_rt.frames, 25, "1000ms at 25fps should be 25 frames") -- 1s * 25fps = 25 frames
local ms_again = time_utils.to_milliseconds(ms_rt)
assert_close(ms_again, 1000.0, 0.1, "Milliseconds round-trip should be within tolerance")

-- Test direct Rational creation
local r = time_utils.rational(10, 30, 1)
assert_true(getmetatable(r) == Rational.metatable, "rational should return a Rational object")
assert_equal(r.frames, 10, "rational frames")
assert_equal(r.fps_numerator, 30, "rational fps_numerator")

-- Test comparison
local r1 = time_utils.from_frames(10, 25) -- 0.4s
local r2 = time_utils.from_frames(12, 30) -- 0.4s
local r3 = time_utils.from_frames(11, 25) -- 0.44s

assert_equal(time_utils.compare(r1, r2), 0, "r1 == r2")
assert_equal(time_utils.compare(r1, r3), -1, "r1 < r3")
assert_equal(time_utils.compare(r3, r1), 1, "r3 > r1")

print("✅ time_utils tests passed")
