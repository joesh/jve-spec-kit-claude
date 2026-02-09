--- Test: edge_drag_renderer handles integer coordinates properly
-- Post-refactor: All coordinates are now plain integers, not Rationals
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

-- Stub edge_utils
package.loaded["ui.timeline.edge_utils"] = {
    to_bracket = function(e) return e end,
}

local Renderer = require("ui.timeline.edge_drag_renderer")

-- Test 1: compute_preview_geometry with clip that has non-integer coords returns nil
local clip_bad = {
    timeline_start = { frames = 0 },   -- plain table, not an integer
    duration = { frames = 100 },        -- plain table, not an integer
}
local s1, d1 = Renderer.compute_preview_geometry(clip_bad, "out", 5)
check("compute_preview_geometry returns nil for non-integer coords", s1 == nil and d1 == nil)

-- Test 2: compute_preview_geometry with proper integer clip works
local clip_ok = {
    timeline_start = 0,
    duration = 100,
}
local new_start, new_dur = Renderer.compute_preview_geometry(clip_ok, "out", 5)
check("compute_preview_geometry works with integer clip", new_start ~= nil)
check("out edge extends duration by delta", new_dur == 105)

-- Test 3: nil clip returns nil (valid early exit)
local s, d = Renderer.compute_preview_geometry(nil, "out", 5)
check("nil clip returns nil", s == nil and d == nil)

-- Test 4: compute_preview_geometry with gap_after edge on clip with bad coords returns nil
local s4, d4 = Renderer.compute_preview_geometry(clip_bad, "out", 5, "gap_after")
check("gap_after with non-integer coords returns nil", s4 == nil and d4 == nil)

-- Test 5: gap_after returns zero-width at clip end
local gap_start, gap_dur = Renderer.compute_preview_geometry(clip_ok, "out", 10, "gap_after")
check("gap_after positioned at clip end", gap_start == 100)
check("gap_after has zero duration", gap_dur == 0)

if failed > 0 then
    print(string.format("❌ test_edge_drag_renderer_no_fps_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_edge_drag_renderer_no_fps_fallback.lua passed (%d assertions)", passed))
