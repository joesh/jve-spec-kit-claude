#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

local Rational = require("core.rational")
local edge_drag_renderer = require("ui.timeline.edge_drag_renderer")

local colors = {
    edge_selected_available = "#00ff00",
    edge_selected_limit = "#ff0000"
}

local function rational(frames)
    return Rational.new(frames, 1000, 1)
end

local gap_edge = {
    clip_id = "temp_gap_track_v1",
    edge_type = "gap_after",
    track_id = "track_v1",
    trim_type = "ripple"
}

local clip_edge = {
    clip_id = "clip_v2",
    edge_type = "out",
    track_id = "track_v2",
    trim_type = "ripple"
}

local lead_edge = gap_edge
local drag_delta = rational(-400) -- Drag gap [ handle to the left

local previews = edge_drag_renderer.build_preview_edges(
    {gap_edge, clip_edge},
    drag_delta,
    {},
    colors,
    lead_edge
)

local by_id = {}
for _, preview in ipairs(previews) do
    by_id[preview.clip_id] = preview
end

assert(by_id[gap_edge.clip_id], "Gap edge preview missing")
assert(by_id[clip_edge.clip_id], "Clip edge preview missing")

assert(by_id[gap_edge.clip_id].delta.frames == -400,
    string.format("Gap handle should follow drag delta (-400); got %s", tostring(by_id[gap_edge.clip_id].delta.frames)))

assert(by_id[clip_edge.clip_id].delta.frames == 400,
    string.format("Opposing clip edge should move opposite lead handle; expected 400, got %s",
        tostring(by_id[clip_edge.clip_id].delta.frames)))

assert(by_id[gap_edge.clip_id].color == colors.edge_selected_available,
    string.format("Moving edges should keep configured color; expected %s, got %s",
        colors.edge_selected_available, tostring(by_id[gap_edge.clip_id].color)))

print("✅ Edge preview uses lead handle to orient opposing bracket deltas")
