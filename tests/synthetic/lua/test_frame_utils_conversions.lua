--- Test: frame_utils.lua conversion functions
-- Coverage: frames_to_ms, ms_to_frames, frame_duration, frame_duration_ms, get_fps_float
-- Tests both happy paths and error paths (type validation, positive fps)
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local frame_utils = require("core.frame_utils")

-- ============================================================================
-- frames_to_ms tests
-- ============================================================================

print("Test: frames_to_ms with valid inputs")
-- 100 frames at 25fps = 100 * 1 * 1000 / 25 = 4000ms
local ms = frame_utils.frames_to_ms(100, 25, 1)
check("100 frames at 25fps = 4000ms", math.abs(ms - 4000) < 0.001)
print("  ✓ frames_to_ms basic conversion")

print("Test: frames_to_ms with 29.97 fps (30000/1001)")
-- 30 frames at 30000/1001 = 30 * 1001 * 1000 / 30000 = 1001ms
ms = frame_utils.frames_to_ms(30, 30000, 1001)
check("30 frames at 29.97fps ≈ 1001ms", math.abs(ms - 1001) < 0.001)
print("  ✓ frames_to_ms with NTSC drop-frame rate")

print("Test: frames_to_ms with zero frames")
ms = frame_utils.frames_to_ms(0, 24, 1)
check("0 frames = 0ms", ms == 0)
print("  ✓ frames_to_ms handles zero")

print("Test: frames_to_ms with nil frames asserts")
local ok, err = pcall(function()
    frame_utils.frames_to_ms(nil, 24, 1)
end)
check("nil frames asserts", not ok)
check("error mentions frames", err and tostring(err):find("frames") ~= nil)
print("  ✓ frames_to_ms validates frames type")

print("Test: frames_to_ms with string frames asserts")
ok = pcall(function()
    frame_utils.frames_to_ms("100", 24, 1)
end)
check("string frames asserts", not ok)
print("  ✓ frames_to_ms rejects string frames")

print("Test: frames_to_ms with nil fps_num asserts")
ok, err = pcall(function()
    frame_utils.frames_to_ms(100, nil, 1)
end)
check("nil fps_num asserts", not ok)
check("error mentions fps_num", err and tostring(err):find("fps_num") ~= nil)
print("  ✓ frames_to_ms validates fps_num")

print("Test: frames_to_ms with zero fps_num asserts")
ok, err = pcall(function()
    frame_utils.frames_to_ms(100, 0, 1)
end)
check("zero fps_num asserts", not ok)
check("error mentions positive", err and tostring(err):find("positive") ~= nil)
print("  ✓ frames_to_ms requires positive fps_num")

print("Test: frames_to_ms with negative fps_num asserts")
ok = pcall(function()
    frame_utils.frames_to_ms(100, -24, 1)
end)
check("negative fps_num asserts", not ok)
print("  ✓ frames_to_ms rejects negative fps_num")

print("Test: frames_to_ms with nil fps_den asserts")
ok, err = pcall(function()
    frame_utils.frames_to_ms(100, 24, nil)
end)
check("nil fps_den asserts", not ok)
check("error mentions fps_den", err and tostring(err):find("fps_den") ~= nil)
print("  ✓ frames_to_ms validates fps_den")

print("Test: frames_to_ms with zero fps_den asserts")
ok = pcall(function()
    frame_utils.frames_to_ms(100, 24, 0)
end)
check("zero fps_den asserts", not ok)
print("  ✓ frames_to_ms requires positive fps_den")

-- ============================================================================
-- ms_to_frames tests
-- ============================================================================

print("Test: ms_to_frames with valid inputs")
-- 4000ms at 25fps = 4000 * 25 / (1 * 1000) = 100 frames
local frames = frame_utils.ms_to_frames(4000, 25, 1)
check("4000ms at 25fps = 100 frames", frames == 100)
print("  ✓ ms_to_frames basic conversion")

print("Test: ms_to_frames with 29.97 fps (30000/1001)")
-- 1001ms at 30000/1001 = round(1001 * 30000 / (1001 * 1000)) = round(30) = 30
frames = frame_utils.ms_to_frames(1001, 30000, 1001)
check("1001ms at 29.97fps = 30 frames", frames == 30)
print("  ✓ ms_to_frames with NTSC drop-frame rate")

print("Test: ms_to_frames rounds to nearest frame")
-- 42ms at 24fps = round(42 * 24 / 1000) = round(1.008) = 1
frames = frame_utils.ms_to_frames(42, 24, 1)
check("42ms at 24fps rounds to 1", frames == 1)
-- 20ms at 24fps = round(20 * 24 / 1000) = round(0.48) = 0
frames = frame_utils.ms_to_frames(20, 24, 1)
check("20ms at 24fps rounds to 0", frames == 0)
print("  ✓ ms_to_frames rounds correctly")

print("Test: ms_to_frames with nil ms asserts")
ok, err = pcall(function()
    frame_utils.ms_to_frames(nil, 24, 1)
end)
check("nil ms asserts", not ok)
check("error mentions ms", err and tostring(err):find("ms") ~= nil)
print("  ✓ ms_to_frames validates ms type")

print("Test: ms_to_frames with string ms asserts")
ok = pcall(function()
    frame_utils.ms_to_frames("4000", 24, 1)
end)
check("string ms asserts", not ok)
print("  ✓ ms_to_frames rejects string ms")

print("Test: ms_to_frames with nil fps_num asserts")
ok = pcall(function()
    frame_utils.ms_to_frames(1000, nil, 1)
end)
check("nil fps_num asserts (ms_to_frames)", not ok)
print("  ✓ ms_to_frames validates fps_num")

print("Test: ms_to_frames with zero fps_den asserts")
ok = pcall(function()
    frame_utils.ms_to_frames(1000, 24, 0)
end)
check("zero fps_den asserts (ms_to_frames)", not ok)
print("  ✓ ms_to_frames requires positive fps_den")

-- ============================================================================
-- frame_duration tests
-- ============================================================================

print("Test: frame_duration returns Rational")
local dur = frame_utils.frame_duration({ fps_numerator = 24, fps_denominator = 1 })
check("frame_duration returns table", type(dur) == "table")
check("frame_duration.frames is 1", dur.frames == 1)
check("frame_duration.fps_numerator is 24", dur.fps_numerator == 24)
print("  ✓ frame_duration creates correct Rational")

print("Test: frame_duration with number rate")
dur = frame_utils.frame_duration(30)
check("frame_duration(30) works", dur.fps_numerator == 30)
print("  ✓ frame_duration handles number rate")

-- ============================================================================
-- frame_duration_ms tests
-- ============================================================================

print("Test: frame_duration_ms with table rate")
-- 1 frame at 24fps = 1000 / 24 = 41.666...ms
local dur_ms = frame_utils.frame_duration_ms({ fps_numerator = 24, fps_denominator = 1 })
check("1 frame at 24fps ≈ 41.67ms", math.abs(dur_ms - 41.666666) < 0.01)
print("  ✓ frame_duration_ms with table rate")

print("Test: frame_duration_ms with 29.97fps")
-- 1 frame at 30000/1001 = 1001/30000 * 1000 = 33.366...ms
dur_ms = frame_utils.frame_duration_ms({ fps_numerator = 30000, fps_denominator = 1001 })
check("1 frame at 29.97fps ≈ 33.37ms", math.abs(dur_ms - 33.3666) < 0.01)
print("  ✓ frame_duration_ms with NTSC rate")

-- ============================================================================
-- get_fps_float tests
-- ============================================================================

print("Test: get_fps_float with table rate")
local fps = frame_utils.get_fps_float({ fps_numerator = 24000, fps_denominator = 1001 })
check("24000/1001 ≈ 23.976", math.abs(fps - 23.976) < 0.01)
print("  ✓ get_fps_float with table rate")

print("Test: get_fps_float with number rate")
fps = frame_utils.get_fps_float(30)
check("get_fps_float(30) = 30", fps == 30)
print("  ✓ get_fps_float with number rate")

print("Test: get_fps_float with nil returns 0")
fps = frame_utils.get_fps_float(nil)
check("get_fps_float(nil) = 0", fps == 0)
print("  ✓ get_fps_float handles nil gracefully")

print("Test: get_fps_float with empty table returns 0")
fps = frame_utils.get_fps_float({})
check("get_fps_float({}) = 0", fps == 0)
print("  ✓ get_fps_float handles empty table")

print("Test: get_fps_float with zero denominator returns 0")
fps = frame_utils.get_fps_float({ fps_numerator = 24, fps_denominator = 0 })
check("zero denominator returns 0", fps == 0)
print("  ✓ get_fps_float handles zero denominator")

-- ============================================================================
-- Round-trip tests
-- ============================================================================

print("Test: frames_to_ms -> ms_to_frames round-trip")
local original_frames = 123
ms = frame_utils.frames_to_ms(original_frames, 24, 1)
frames = frame_utils.ms_to_frames(ms, 24, 1)
check("round-trip preserves 123 frames at 24fps", frames == original_frames)

original_frames = 500
ms = frame_utils.frames_to_ms(original_frames, 30000, 1001)
frames = frame_utils.ms_to_frames(ms, 30000, 1001)
check("round-trip preserves 500 frames at 29.97fps", frames == original_frames)
print("  ✓ round-trip conversions preserve frame count")

if failed > 0 then
    print(string.format("❌ test_frame_utils_conversions.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_frame_utils_conversions.lua passed (%d assertions)", passed))
