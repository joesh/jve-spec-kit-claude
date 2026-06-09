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

-- Regression: parse() returns Rational, .frames is integer suitable for set_playhead_position
-- Bug: timeline_panel passed Rational directly to set_playhead_position which expects integer
do
    local value = assert(timecode_input.parse("01:00:00:00", rate))
    assert(type(value) == "table" and value.frames ~= nil, "parse returns Rational with .frames")
    assert(type(value.frames) == "number", ".frames must be a number")
    assert(value.frames == math.floor(value.frames), ".frames must be integer")
    assert_equal(value.frames, 25 * 3600, "1 hour at 25fps = 90000 frames")

    -- Relative parse also returns Rational with integer .frames
    local base = Rational.new(100, rate.fps_numerator, rate.fps_denominator)
    local rel = assert(timecode_input.parse("+50", rate, {base_time = base}))
    assert(type(rel.frames) == "number" and rel.frames == math.floor(rel.frames),
        "relative parse .frames must be integer")
    assert_equal(rel.frames, 150, "relative offset integer frames")

    -- Integer base_time (as timeline_panel passes from get_playhead_position)
    local rel2 = assert(timecode_input.parse("+10", rate, {base_time = 500}))
    assert_equal(rel2.frames, 510, "integer base_time works for relative parse")
end

-- NSF: Error paths — parse must return nil + error string, never silently succeed
do
    local val, err = timecode_input.parse("", rate)
    assert(val == nil, "empty string must return nil")
    assert(type(err) == "string", "empty string must return error string")

    local val2, err2 = timecode_input.parse("   ", rate)
    assert(val2 == nil, "whitespace-only must return nil")
    assert(type(err2) == "string", "whitespace-only must return error string")

    local val3, err3 = timecode_input.parse("abc", rate)
    assert(val3 == nil, "non-numeric must return nil")
    assert(type(err3) == "string", "non-numeric must return error string")

    local val4, err4 = timecode_input.parse("+", rate)
    assert(val4 == nil, "bare sign must return nil")
    assert(type(err4) == "string", "bare sign must return error string")

    -- Missing frame_rate
    local val5, err5 = timecode_input.parse("100", nil)
    assert(val5 == nil, "nil frame_rate must return nil")
    assert(type(err5) == "string", "nil frame_rate must return error string")

    -- Bad frame_rate
    local val6, err6 = timecode_input.parse("100", {fps_numerator = 25, fps_denominator = 0})
    assert(val6 == nil, "zero denominator must return nil")
    assert(type(err6) == "string", "zero denominator must return error string")
end

-- NSF: Boundary — zero frame, negative relative result
do
    local zero = assert(timecode_input.parse("0", rate))
    assert_equal(zero.frames, 0, "zero input yields 0 frames")

    local zero_tc = assert(timecode_input.parse("00:00:00:00", rate))
    assert_equal(zero_tc.frames, 0, "all-zero timecode yields 0 frames")

    -- Negative relative result (playhead near start, large negative offset)
    local base = Rational.new(10, rate.fps_numerator, rate.fps_denominator)
    local neg = assert(timecode_input.parse("-100", rate, {base_time = base}))
    assert_equal(neg.frames, -90, "negative relative result is allowed (caller clamps)")
    assert(type(neg.frames) == "number" and neg.frames == math.floor(neg.frames),
        "negative result .frames still integer")
end

print("✅ timecode_input tests passed")
