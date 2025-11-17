#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

local edge_drag_renderer = require("ui.timeline.edge_drag_renderer")

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

print("✅ edge drag preview clamp test passed")
