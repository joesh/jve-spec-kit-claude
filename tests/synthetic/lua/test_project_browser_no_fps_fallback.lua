--- Test: clip-shape rate input is single-shape (frame_rate table only)
-- Regression: source-mark math used to fabricate 24fps when fps was missing,
-- then briefly accepted dual shape (frame_rate table OR flat fps_numerator).
-- Both are gone. Clip rows MUST carry the frame_rate table or fail loud.
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local Rational = require("core.rational")

-- Canonical pattern: frame_rate table is the only accepted shape.
-- Flat fps_numerator on a clip is no longer recognized as a rate carrier.
local function apply_source_marks_pattern(clip, mark_in, mark_out)
    assert(clip.frame_rate
        and clip.frame_rate.fps_numerator
        and clip.frame_rate.fps_denominator,
        "clip missing frame_rate table for clip " .. tostring(clip.clip_id))
    local fr = clip.frame_rate
    return Rational.new(mark_in, fr.fps_numerator, fr.fps_denominator),
           Rational.new(mark_out, fr.fps_numerator, fr.fps_denominator)
end

-- Test 1: clip with no frame_rate asserts
local ok1, err1 = pcall(function()
    apply_source_marks_pattern({ clip_id = "clip1" }, 0, 100)
end)
check("asserts on clip with no frame_rate", not ok1)
check("error mentions frame_rate", err1 and tostring(err1):find("frame_rate") ~= nil)

-- Test 2: clip with frame_rate table works
local si = apply_source_marks_pattern(
    { clip_id = "clip2", frame_rate = { fps_numerator = 48, fps_denominator = 1 } }, 0, 100)
check("clip with frame_rate works", si.fps_numerator == 48)

-- Test 3: clip with ONLY flat fps_numerator (no table) must NOT silently work
local ok3 = pcall(function()
    apply_source_marks_pattern(
        { clip_id = "clip3", fps_numerator = 25, fps_denominator = 1 }, 0, 100)
end)
check("clip with only flat fps_numerator asserts (no synthesis)", not ok3)

if failed > 0 then
    print(string.format("❌ test_project_browser_no_fps_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_project_browser_no_fps_fallback.lua passed (%d assertions)", passed))
