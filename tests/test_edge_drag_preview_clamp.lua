#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

local edge_drag_renderer = require("ui.timeline.edge_drag_renderer")
local Rational = require("core.rational")

local colors = {
    edge_selected_available = 0x00FF00,
    edge_selected_limit = 0xFF0000,
}

-- Constraints: edge A max 100, edge B max 300. Dragging 250 should clamp both to 100.
local trim_constraints = {
    ["clipA:out"] = {min_delta = -math.huge, max_delta = 100},
    ["clipB:in"] = {min_delta = -math.huge, max_delta = 300},
}

local edges = {
    {clip_id = "clipA", edge_type = "out"},
    {clip_id = "clipB", edge_type = "in"},
}

local previews = edge_drag_renderer.build_preview_edges(edges, 250, trim_constraints, colors)

assert(#previews == 2, "expected two preview edges")
assert(previews[1].delta_ms == 100 and previews[2].delta_ms == 100, "shared clamp should limit both edges to 100ms")
-- Only the edge with the tightest constraint should show limit/red
assert(previews[1].at_limit ~= previews[2].at_limit, "only the limiting edge should hit the limit")

-- Zero delta should never flag at_limit
local zero_previews = edge_drag_renderer.build_preview_edges(edges, 0, trim_constraints, colors)
for _, p in ipairs(zero_previews) do
    assert(p.at_limit == false, "zero delta should not be marked at_limit")
end

-- Regression: gap edges should behave like anchored clip handles, not translations.
local clip = {
    timeline_start = Rational.new(100, 24, 1),
    duration = Rational.new(200, 24, 1)
}
local delta = Rational.new(24, 24, 1) -- 1 second
local gap_start, gap_dur = edge_drag_renderer.compute_preview_geometry(clip, "gap_after", delta)
local expected_gap_anchor = (clip.timeline_start + clip.duration).frames
assert(gap_start.frames == expected_gap_anchor,
    string.format("gap_after preview should anchor at clip out-point; expected %d got %d", expected_gap_anchor, gap_start and gap_start.frames or -1))
assert(gap_dur.frames == 0, "gap preview geometry should have zero width (handle only)")

print("✅ edge drag preview clamp test passed")
