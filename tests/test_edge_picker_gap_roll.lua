#!/usr/bin/env luajit

-- Regression: roll selection between a gap clip and a media clip should
-- include both edges (gap:out + clip:in).
-- (Updated for gap-as-clip: gaps are real clips in the track list.)

require("test_env")

local edge_picker = require("ui.timeline.edge_picker")

local gap_clip = {
    id = "gap_track_v1_0",
    track_id = "track_v1",
    timeline_start = 0,
    duration = 2000,
    clip_kind = "gap"
}

local media_clip = {
    id = "clip_gap_right",
    name = "Right Clip",
    track_id = "track_v1",
    timeline_start = 2000,
    duration = 600,
    clip_kind = "timeline"
}

local track_clips = {gap_clip, media_clip}

local viewport_width = 4000
local function time_to_pixel(time)
    return time
end

local boundary_px = media_clip.timeline_start
local result = edge_picker.pick_edges(track_clips, boundary_px, viewport_width, {
    edge_zone = 20,
    roll_zone = 20,
    time_to_pixel = time_to_pixel
})

assert(result.roll_used, "Gap + clip boundary should allow roll selection")
assert(result.selection and #result.selection == 2, "Roll selection should include both edges")

local has_gap_edge = false
local has_clip_edge = false
for _, entry in ipairs(result.selection or {}) do
    if entry.clip_id == "gap_track_v1_0" and entry.edge_type == "out" then
        has_gap_edge = true
    elseif entry.clip_id == "clip_gap_right" and entry.edge_type == "in" then
        has_clip_edge = true
    end
    assert(entry.trim_type == "roll", "Roll selection entries must be marked trim_type=roll")
end

assert(has_gap_edge, "Roll selection should include the gap clip's out edge")
assert(has_clip_edge, "Roll selection should include the media clip's in edge")

print("✅ edge_picker supports roll selection between gap clip and media clip")
