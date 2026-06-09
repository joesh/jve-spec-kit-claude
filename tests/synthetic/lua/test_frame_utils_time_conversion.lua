--- Test: frame_utils.lua Rational time conversion functions
-- Coverage: time_to_frame, frame_to_time, snap_to_frame, snap_delta_to_frame
-- Tests both happy paths and error paths (hydrate failures)
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local frame_utils = require("core.frame_utils")
local Rational = require("core.rational")

local rate_24 = { fps_numerator = 24, fps_denominator = 1 }
local _rate_2997 = { fps_numerator = 30000, fps_denominator = 1001 }  -- luacheck: no unused

-- ============================================================================
-- time_to_frame tests
-- ============================================================================

print("Test: time_to_frame with Rational object")
local r = Rational.new(100, 24, 1)
local frame, success = frame_utils.time_to_frame(r, rate_24)
check("time_to_frame returns 100", frame == 100)
check("time_to_frame returns success true", success == true)
print("  ✓ time_to_frame with Rational")

print("Test: time_to_frame with integer (hydrates)")
frame, success = frame_utils.time_to_frame(50, rate_24)
check("time_to_frame(50) returns 50", frame == 50)
check("time_to_frame(50) success", success == true)
print("  ✓ time_to_frame hydrates integer")

print("Test: time_to_frame rescales different rates")
-- 30 frames at 30fps needs to be expressed at 24fps
-- 30 frames * (24/30) = 24 frames
local r_30fps = Rational.new(30, 30, 1)
frame = frame_utils.time_to_frame(r_30fps, rate_24)
check("30 frames at 30fps -> 24 at 24fps", frame == 24)
print("  ✓ time_to_frame rescales")

print("Test: time_to_frame with nil time_obj asserts")
local ok, err = pcall(function()
    frame_utils.time_to_frame(nil, rate_24)
end)
check("nil time_obj asserts", not ok)
check("error mentions hydrate", err and tostring(err):find("hydrate") ~= nil)
print("  ✓ time_to_frame validates time_obj")

print("Test: time_to_frame with invalid rate asserts via normalize_rate")
ok = pcall(function()
    frame_utils.time_to_frame(100, nil)
end)
check("nil rate asserts", not ok)
print("  ✓ time_to_frame validates rate")

-- ============================================================================
-- frame_to_time tests
-- ============================================================================

print("Test: frame_to_time creates Rational")
local time_obj = frame_utils.frame_to_time(100, rate_24)
check("frame_to_time returns table", type(time_obj) == "table")
check("frame_to_time.frames is 100", time_obj.frames == 100)
check("frame_to_time.fps_numerator is 24", time_obj.fps_numerator == 24)
check("frame_to_time.fps_denominator is 1", time_obj.fps_denominator == 1)
print("  ✓ frame_to_time creates Rational")

print("Test: frame_to_time with number rate")
time_obj = frame_utils.frame_to_time(50, 30)
check("frame_to_time(50, 30) works", time_obj.frames == 50)
check("frame_to_time.fps_numerator is 30", time_obj.fps_numerator == 30)
print("  ✓ frame_to_time handles number rate")

print("Test: frame_to_time with negative frames")
time_obj = frame_utils.frame_to_time(-10, rate_24)
check("negative frame creates Rational", time_obj.frames == -10)
print("  ✓ frame_to_time handles negative frames")

-- ============================================================================
-- snap_to_frame tests
-- ============================================================================

print("Test: snap_to_frame with same rate")
local r_same = Rational.new(100, 24, 1)
local snapped = frame_utils.snap_to_frame(r_same, rate_24)
check("snap_to_frame same rate preserves frames", snapped.frames == 100)
check("snap_to_frame same rate preserves rate", snapped.fps_numerator == 24)
print("  ✓ snap_to_frame with same rate")

print("Test: snap_to_frame rescales")
-- 30 frames at 30fps = 1 second = 24 frames at 24fps
local r_different = Rational.new(30, 30, 1)
snapped = frame_utils.snap_to_frame(r_different, rate_24)
check("snap 30@30fps to 24fps = 24", snapped.frames == 24)
check("snapped has target rate", snapped.fps_numerator == 24)
print("  ✓ snap_to_frame rescales to target rate")

print("Test: snap_to_frame with integer")
snapped = frame_utils.snap_to_frame(75, rate_24)
check("snap_to_frame(75) = 75", snapped.frames == 75)
print("  ✓ snap_to_frame hydrates integer")

print("Test: snap_to_frame with nil time_obj asserts")
ok, err = pcall(function()
    frame_utils.snap_to_frame(nil, rate_24)
end)
check("nil time_obj asserts (snap)", not ok)
check("error mentions hydrate (snap)", err and tostring(err):find("hydrate") ~= nil)
print("  ✓ snap_to_frame validates time_obj")

-- ============================================================================
-- snap_delta_to_frame tests
-- ============================================================================

print("Test: snap_delta_to_frame delegates to snap_to_frame")
local delta = Rational.new(10, 24, 1)
snapped = frame_utils.snap_delta_to_frame(delta, rate_24)
check("snap_delta_to_frame returns Rational", type(snapped) == "table")
check("snap_delta_to_frame.frames is 10", snapped.frames == 10)
print("  ✓ snap_delta_to_frame works")

print("Test: snap_delta_to_frame with integer")
snapped = frame_utils.snap_delta_to_frame(5, rate_24)
check("snap_delta_to_frame(5) = 5", snapped.frames == 5)
print("  ✓ snap_delta_to_frame hydrates integer")

-- ============================================================================
-- Round-trip tests
-- ============================================================================

print("Test: frame_to_time -> time_to_frame round-trip")
for _, original in ipairs({0, 1, 100, 1000, -50}) do  -- luacheck: ignore _
    time_obj = frame_utils.frame_to_time(original, rate_24)
    frame = frame_utils.time_to_frame(time_obj, rate_24)
    check(string.format("round-trip preserves %d", original), frame == original)
end
print("  ✓ round-trip preserves frame values")

print("Test: round-trip through different rates")
-- 120 frames at 24fps = 5 seconds = 150 frames at 30fps
-- Then back: 150 frames at 30fps = 5 seconds = 120 frames at 24fps
local rate_30 = { fps_numerator = 30, fps_denominator = 1 }
local original = 120
time_obj = frame_utils.frame_to_time(original, rate_24)
frame = frame_utils.time_to_frame(time_obj, rate_30)
check("120@24fps -> 150@30fps", frame == 150)
local back = frame_utils.frame_to_time(frame, rate_30)
local final = frame_utils.time_to_frame(back, rate_24)
check("150@30fps -> 120@24fps", final == 120)
print("  ✓ cross-rate round-trip works")

if failed > 0 then
    print(string.format("❌ test_frame_utils_time_conversion.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_frame_utils_time_conversion.lua passed (%d assertions)", passed))
