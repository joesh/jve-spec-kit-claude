#!/usr/bin/env luajit

require("test_env")

local edge_picker = require("ui.timeline.edge_picker")
local Rational = require("core.rational")

local track_clips = {
    {
        id = "clip_gap_right",
        name = "Right Clip",
        track_id = "track_v1",
        timeline_start = Rational.new(2000, 1000, 1),
        duration = Rational.new(600, 1000, 1)
    }
}

local viewport_width = 4000
local function time_to_pixel(time)
    return time.frames
end

local boundary_px = track_clips[1].timeline_start.frames
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
    if entry.edge_type == "gap_before" then
        has_gap_edge = true
    elseif entry.edge_type == "in" then
        has_clip_edge = true
    end
    assert(entry.trim_type == "roll", "Roll selection entries must be marked trim_type=roll")
end

assert(has_gap_edge, "Roll selection should include the gap edge")
assert(has_clip_edge, "Roll selection should include the neighboring clip edge")

print("✅ edge_picker supports roll selection between a gap edge and clip edge")
