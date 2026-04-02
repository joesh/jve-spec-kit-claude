#!/usr/bin/env luajit

require("test_env")

local edge_drag_renderer = require("ui.timeline.edge_drag_renderer")

-- Gap clips use standard in/out edges, same as media clips.
-- Verify that compute_preview_geometry handles gap clip edges correctly.

local gap_clip = {
    id = "gap_track_v1_2000",
    track_id = "track_v1",
    timeline_start = 2000,
    duration = 1000,
    clip_kind = "gap"
}

local colors = {
    edge_selected_available = "#00ff00",
    edge_selected_limit = "#ff0000"
}

-- Gap clip "out" edge drag (extending gap duration)
local drag_edges = {
    {clip_id = gap_clip.id, edge_type = "out", track_id = gap_clip.track_id}
}

local delta = 500

local previews = edge_drag_renderer.build_preview_edges(drag_edges, delta, {}, colors)
assert(#previews == 1, "expected a single preview entry")

local preview = previews[1]
assert(preview.edge_type == "out", string.format("expected out edge, got %s", tostring(preview.edge_type)))

local start, duration = edge_drag_renderer.compute_preview_geometry(
    gap_clip,
    preview.edge_type,
    preview.delta
)

-- Out edge should extend duration
assert(duration == gap_clip.duration + delta,
    string.format("out edge should extend gap duration; expected %d got %d",
        gap_clip.duration + delta, duration or -1))
assert(start == gap_clip.timeline_start,
    string.format("out edge should preserve start; expected %d got %d",
        gap_clip.timeline_start, start or -1))

-- Gap clip "in" edge drag (shortening from left)
local in_start, in_duration = edge_drag_renderer.compute_preview_geometry(
    gap_clip, "in", 200)
assert(in_duration == gap_clip.duration - 200,
    string.format("in edge should shorten gap; expected %d got %d",
        gap_clip.duration - 200, in_duration or -1))
assert(in_start == gap_clip.timeline_start,
    string.format("in edge should preserve start; expected %d got %d",
        gap_clip.timeline_start, in_start or -1))

print("✅ edge_drag_renderer handles gap clip edges with standard in/out geometry")
