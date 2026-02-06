--- Test: edge_drag_renderer asserts fps instead of falling back to 30fps
-- Regression: negate_delta and compute_preview_geometry used "or 30" for fps
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local Rational = require("core.rational")

-- Stub edge_utils
package.loaded["ui.timeline.edge_utils"] = {
    to_bracket = function(e) return e end,
}

local Renderer = require("ui.timeline.edge_drag_renderer")

-- Test 1: compute_preview_geometry with clip whose timeline_start/duration lack fps should assert
local clip_no_fps = {
    timeline_start = { frames = 0 },   -- plain table, no fps_numerator
    duration = { frames = 100 },        -- plain table, no fps_numerator
}
local ok1, err1 = pcall(function()
    Renderer.compute_preview_geometry(clip_no_fps, "out", Rational.new(5, 24, 1))
end)
check("compute_preview_geometry asserts on missing fps", not ok1)
check("error mentions fps", err1 and tostring(err1):find("fps") ~= nil)

-- Test 2: compute_preview_geometry with proper Rational clip works
local clip_ok = {
    timeline_start = Rational.new(0, 24, 1),
    duration = Rational.new(100, 24, 1),
}
local new_start, new_dur = Renderer.compute_preview_geometry(clip_ok, "out", Rational.new(5, 24, 1))
check("compute_preview_geometry works with Rational clip", new_start ~= nil)

-- Test 3: nil clip returns nil (valid early exit)
local s, d = Renderer.compute_preview_geometry(nil, "out", Rational.new(5, 24, 1))
check("nil clip returns nil", s == nil and d == nil)

-- Test 4: compute_preview_geometry with gap_after edge on clip with no fps
local ok4, err4 = pcall(function()
    Renderer.compute_preview_geometry(clip_no_fps, "out", Rational.new(5, 24, 1), "gap_after")
end)
check("gap_after with no fps asserts", not ok4)
check("gap_after error mentions fps", err4 and tostring(err4):find("fps") ~= nil)

if failed > 0 then
    print(string.format("❌ test_edge_drag_renderer_no_fps_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_edge_drag_renderer_no_fps_fallback.lua passed (%d assertions)", passed))
