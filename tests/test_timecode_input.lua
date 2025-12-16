package.path = package.path .. ";src/lua/?.lua;src/lua/?/init.lua;./?.lua;./?/init.lua"

local timecode_input = require("core.timecode_input")
local Rational = require("core.rational")

local function assert_equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("Assertion failed: %s\nExpected: %s\nActual:   %s", message or "", tostring(expected), tostring(actual)))
    end
end

local rate = {fps_numerator = 25, fps_denominator = 1}

do
    local value, err = timecode_input.parse("01:02:03:04", rate)
    assert_equal(err, nil, "strict 4-field timecode should parse")
    assert_equal(value.frames, 25 * (1 * 3600 + 2 * 60 + 3) + 4, "strict timecode frames")
end

do
    local value = assert(timecode_input.parse("1:23", rate))
    assert_equal(value.frames, 25 * 1 + 23, "right-aligned 2-field segments")

    local value2 = assert(timecode_input.parse("1:02:03", rate))
    assert_equal(value2.frames, 25 * (1 * 60 + 2) + 3, "right-aligned 3-field segments")
end

do
    local value = assert(timecode_input.parse("1234", rate))
    assert_equal(value.frames, 25 * 12 + 34, "right-aligned digit entry")

    local value2 = assert(timecode_input.parse("1", rate))
    assert_equal(value2.frames, 1, "single digit becomes one frame")
end

do
    local base = Rational.new(1000, rate.fps_numerator, rate.fps_denominator)
    local value = assert(timecode_input.parse("+10", rate, {base_time = base}))
    assert_equal(value.frames, 1010, "relative +frames offset")
end

do
    local base = Rational.new(1000, rate.fps_numerator, rate.fps_denominator)
    local value = assert(timecode_input.parse("+1:00", rate, {base_time = base}))
    assert_equal(value.frames, 1000 + 25, "relative timecode offset")
end

do
    local value = assert(timecode_input.parse("2s", rate))
    assert_equal(value.frames, 50, "suffixed seconds duration")

    local base = Rational.new(1000, rate.fps_numerator, rate.fps_denominator)
    local value2 = assert(timecode_input.parse("-3m", rate, {base_time = base}))
    assert_equal(value2.frames, 1000 - 3 * 60 * 25, "relative minutes duration")
end

do
    local value = assert(timecode_input.parse("10:", rate))
    assert_equal(value.frames, 10 * 25, "trailing colon implies missing frames (SS:FF)")

    local value2 = assert(timecode_input.parse("10::", rate))
    assert_equal(value2.frames, 10 * 60 * 25, "multiple separators imply additional zero fields")

    local value3 = assert(timecode_input.parse("10..", rate))
    assert_equal(value3.frames, 10 * 60 * 25, "period behaves like colon with missing fields as zeros")
end

print("✅ timecode_input tests passed")
