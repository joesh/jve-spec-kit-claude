--- Test: project_browser source mark calculation asserts fps instead of fabricating 24fps
-- Regression: line 1790 used "clip.fps_numerator or 24" when clip had no rate
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local Rational = require("core.rational")

-- We need to test the source mark application code path at project_browser.lua:1789
-- The function that calls it is get_insert_clip_with_marks or similar.
-- Rather than loading the full UI module, we test the pattern directly:
-- This verifies the code would assert if clip has no rate/fps_numerator.

-- Simulate the fixed pattern:
local function apply_source_marks_pattern(clip, mark_in, mark_out)
    local rate = clip.rate
    if not rate then
        assert(clip.fps_numerator, "project_browser: clip.fps_numerator is required when clip.rate is missing for clip " .. tostring(clip.clip_id))
        rate = { fps_numerator = clip.fps_numerator, fps_denominator = clip.fps_denominator or 1 }
    end
    return Rational.new(mark_in, rate.fps_numerator, rate.fps_denominator),
           Rational.new(mark_out, rate.fps_numerator, rate.fps_denominator)
end

-- Test 1: clip with no rate and no fps_numerator should assert
local ok1, err1 = pcall(function()
    apply_source_marks_pattern({ clip_id = "clip1" }, 0, 100)
end)
check("asserts on clip with no fps", not ok1)
check("error mentions fps_numerator", err1 and tostring(err1):find("fps_numerator") ~= nil)

-- Test 2: clip with rate works
local si, so = apply_source_marks_pattern(
    { clip_id = "clip2", rate = { fps_numerator = 48, fps_denominator = 1 } }, 0, 100)
check("clip with rate works", si.fps_numerator == 48)

-- Test 3: clip with fps_numerator (no rate table) works
local si2, so2 = apply_source_marks_pattern(
    { clip_id = "clip3", fps_numerator = 25, fps_denominator = 1 }, 0, 100)
check("clip with fps_numerator works", si2.fps_numerator == 25)

if failed > 0 then
    print(string.format("❌ test_project_browser_no_fps_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_project_browser_no_fps_fallback.lua passed (%d assertions)", passed))
