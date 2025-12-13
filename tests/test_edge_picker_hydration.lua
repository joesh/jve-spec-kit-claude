#!/usr/bin/env luajit
-- Regression: edge_picker must hydrate clip bounds to Rational and not crash when timeline_start/duration are plain tables.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local edge_picker = require("ui.timeline.edge_picker")

local clip = {
    id = "c1",
    track_id = "v1",
    timeline_start = {frames = 0, fps_numerator = 24, fps_denominator = 1},
    duration = {frames = 24, fps_numerator = 24, fps_denominator = 1},
}

local track_clips = {clip}

local function time_to_pixel(rt, _width)
    return (rt.frames or 0)
end

local ok, result = pcall(function()
    return edge_picker.pick_edges(track_clips, 0, 1000, {
        edge_zone = 8,
        roll_zone = 6,
        time_to_pixel = time_to_pixel
    })
end)

assert(ok, "edge_picker.pick_edges errored: " .. tostring(result))
assert(result and type(result.selection) == "table", "edge_picker.pick_edges returned invalid result")
print("✅ edge_picker hydrates clip bounds and avoids crashes with table timeline_start/duration")
