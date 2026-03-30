-- Edge case tests for frame_utils: invalid fps, field overflow, NTSC rates.

require("test_env")

local frame_utils = require("core.frame_utils")

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
end

print("\n=== frame_utils Edge Case Tests ===")

-- ── fps=0 asserts (no silent fallback) ──
print("\n--- Invalid fps ---")
expect_error("format_timecode fps=0 asserts",
    function()
        frame_utils.format_timecode(100, {fps_numerator = 0, fps_denominator = 1})
    end,
    "fps_numerator must be positive")

expect_error("parse_timecode fps=0 asserts",
    function()
        frame_utils.parse_timecode("00:00:01:00", {fps_numerator = 0, fps_denominator = 1})
    end,
    "invalid fps")

-- ── Standard rates format correctly ──
print("\n--- Standard rates ---")
local function fmt(frames, num, den)
    return frame_utils.format_timecode(frames, {fps_numerator = num, fps_denominator = den})
end

check("24fps: 0 = 00:00:00:00", fmt(0, 24, 1) == "00:00:00:00")
check("24fps: 24 = 00:00:01:00", fmt(24, 24, 1) == "00:00:01:00")
check("24fps: 86400 = 01:00:00:00", fmt(86400, 24, 1) == "01:00:00:00")

check("25fps: 25 = 00:00:01:00", fmt(25, 25, 1) == "00:00:01:00")
check("25fps: 90000 = 01:00:00:00", fmt(90000, 25, 1) == "01:00:00:00")

-- NTSC 29.97 (30000/1001) rounds to 30 for NDF display
check("29.97 NDF: 30 = 00:00:01:00", fmt(30, 30000, 1001) == "00:00:01:00")
check("29.97 NDF: 108000 = 01:00:00:00", fmt(108000, 30000, 1001) == "01:00:00:00")

-- ── Parse roundtrip ──
print("\n--- Parse roundtrip ---")
local function roundtrip(tc_str, num, den)
    local rate = {fps_numerator = num, fps_denominator = den}
    local parsed = frame_utils.parse_timecode(tc_str, rate)
    if not parsed then return nil end
    return frame_utils.format_timecode(parsed.frames, rate)
end

check("24fps roundtrip 01:02:03:04", roundtrip("01:02:03:04", 24, 1) == "01:02:03:04")
check("25fps roundtrip 00:59:59:24", roundtrip("00:59:59:24", 25, 1) == "00:59:59:24")
check("30fps roundtrip 12:34:56:29", roundtrip("12:34:56:29", 30, 1) == "12:34:56:29")

-- ── 23.976 (24000/1001) ──
print("\n--- 23.976 fps ---")
check("23.976: 24 = 00:00:01:00", fmt(24, 24000, 1001) == "00:00:01:00")
check("23.976: 86400 = 01:00:00:00", fmt(86400, 24000, 1001) == "01:00:00:00")

-- ── Large values (long-form content) ──
print("\n--- Large values ---")
check("24fps: 24h = 24:00:00:00", fmt(86400 * 24, 24, 1) == "24:00:00:00")

-- ── Negative frames ──
print("\n--- Negative frames ---")
local neg_result = fmt(-24, 24, 1)
check("negative: -24 frames has minus sign", neg_result:sub(1, 1) == "-")
check("negative: -24 = -00:00:01:00", neg_result == "-00:00:01:00")

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("✅ test_frame_utils_edge_cases.lua passed")
