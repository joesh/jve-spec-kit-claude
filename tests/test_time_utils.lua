#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

local time_utils = require("core.time_utils")

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual:   %s", message or "", tostring(expected), tostring(actual)))
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
assert_close(time_utils.default_frame_rate, 30.0, 0.01, "Default frame rate should mirror frame_utils.default_frame_rate")

-- Frames to samples and back (1 frame at 24fps -> 2000 samples @48k)
local one_frame = time_utils.from_frames(1, 24)
local samples = time_utils.to_samples(one_frame, 48000, "round")
assert_equal(samples, 2000, "1 frame at 24fps should equal 2000 samples at 48k")
local back_to_frames = time_utils.to_frames(time_utils.from_samples(samples, 48000), 24, "round")
assert_equal(back_to_frames, 1, "Sample conversion should round-trip to 1 frame at 24fps")

-- Rational addition with rate conversion
local five_frames_24 = time_utils.from_frames(5, 24)
local two_frames_30 = time_utils.from_frames(2, 30)
local sum = time_utils.add(five_frames_24, two_frames_30, {mode = "round"})
assert_equal(sum.rate, 24, "Sum should use lhs rate when not overridden")
assert_equal(sum.value, 5 + math.floor((2 * 24 / 30) + 0.5), "Cross-rate add should round into target rate")

-- Milliseconds conversion round trip
local ms_rt = time_utils.from_milliseconds(1000, 25) -- 1s @25fps -> 25 frames equivalent
assert_equal(ms_rt.rate, 25, "from_milliseconds should honor provided rate")
local ms_again = time_utils.to_milliseconds(ms_rt)
assert_close(ms_again, 1000.0, 0.1, "Milliseconds round-trip should be within tolerance")

print("✅ time_utils tests passed")
