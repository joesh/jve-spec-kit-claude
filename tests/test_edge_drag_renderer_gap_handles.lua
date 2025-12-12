#!/usr/bin/env luajit

require("test_env")

local edge_drag_renderer = require("ui.timeline.edge_drag_renderer")
local Rational = require("core.rational")

-- Regression: gap handles should render as zero-width brackets at the gap boundary.
-- build_preview_edges must preserve the original edge_type so compute_preview_geometry
-- can distinguish clip edges from gap edges.

local clip = {
    id = "clip_gap_target",
    track_id = "track_v1",
    timeline_start = Rational.new(2000, 1000, 1),
    duration = Rational.new(1000, 1000, 1)
}

local colors = {
    edge_selected_available = "#00ff00",
    edge_selected_limit = "#ff0000"
}

local drag_edges = {
    {clip_id = clip.id, edge_type = "gap_before", track_id = clip.track_id}
}

local delta = Rational.new(500, 1000, 1)

local previews = edge_drag_renderer.build_preview_edges(drag_edges, delta, {}, colors)
assert(#previews == 1, "expected a single preview entry for the gap handle")

local preview = previews[1]
assert(preview.raw_edge_type == "gap_before",
    string.format("gap preview must preserve raw edge_type, got %s", tostring(preview.raw_edge_type)))

local start, duration = edge_drag_renderer.compute_preview_geometry(
    clip,
    preview.edge_type,
    preview.delta,
    preview.raw_edge_type
)
local expected_start = clip.timeline_start + delta
assert(duration.frames == 0,
    "gap preview should remain zero-width")
assert(start.frames == expected_start.frames,
    string.format("gap preview should move with drag delta; expected %d got %d",
        expected_start.frames, start and start.frames or -1))

print("✅ edge_drag_renderer preserves gap handle geometry for previews")
