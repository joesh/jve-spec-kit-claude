#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

local frame_utils = require("core.frame_utils")

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual:   %s", message or "", tostring(expected), tostring(actual)))
    end
end

local function assert_close(actual, expected, tolerance, message)
    tolerance = tolerance or 1
    if math.abs(actual - expected) > tolerance then
        error(string.format("Assertion failed: %s\nExpected: %s ±%s\nActual:   %s", message or "", tostring(expected), tostring(tolerance), tostring(actual)))
    end
end

local Rational = require("core.rational")

-- Formatting tests (Rational inputs)
assert_equal(frame_utils.format_timecode(Rational.new(0, 24, 1), 24), "00:00:00:00", "Zero time should be all zeros")
assert_equal(frame_utils.format_timecode(Rational.new(24, 24, 1), 24), "00:00:01:00", "1 second should format correctly")
assert_equal(frame_utils.format_timecode(Rational.new(12, 25, 1), 25, {separator = "."}), "00.00.00.12", "Custom separator should be honored")
assert_equal(frame_utils.format_timecode(Rational.new(-48, 24, 1), 24), "-00:00:02:00", "Negative times should include sign")

-- Parsing tests with flexible separators
local parsed_colon = frame_utils.parse_timecode("00:00:10:00", 25)
assert_equal(parsed_colon.frames, 10 * 25, "Colon-separated timecode should parse to 10 seconds (frames)")

local parsed_semicolon = frame_utils.parse_timecode("00:01:00;12", 30)
local expected_semicolon = frame_utils.frame_to_time(30 * 60 + 12, 30)
assert_equal(parsed_semicolon.frames, expected_semicolon.frames, "Semicolon-separated timecode should parse")

local parsed_dot = frame_utils.parse_timecode("00.00.01.12", 25)
local expected_dot = frame_utils.frame_to_time(25 + 12, 25)
assert_equal(parsed_dot.frames, expected_dot.frames, "Dot-separated timecode should parse")

local parsed_comma = frame_utils.parse_timecode("01,02,03,15", 24)
local expected_comma = frame_utils.frame_to_time((1 * 3600 + 2 * 60 + 3) * 24 + 15, 24)
assert_equal(parsed_comma.frames, expected_comma.frames, "Comma-separated timecode should parse")

local parsed_negative = frame_utils.parse_timecode("-00:00:05:00", 30)
assert_equal(parsed_negative.frames, -5 * 30, "Negative timecode should parse")

print("✅ frame_utils timecode tests passed")
