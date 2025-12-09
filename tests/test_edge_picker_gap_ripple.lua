#!/usr/bin/env luajit

-- Regression: picking an edge where only a single clip is present (gap on one side)
-- should not force a roll selection. Previously this returned two edges for the
-- same clip (gap_before + in), which behaved like a roll when the user simply
-- wanted a ripple trim on the upstream clip edge.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local edge_picker = require("ui.timeline.edge_picker")
local Rational = require("core.rational")
local ui_constants = require("core.ui_constants")

local clip = {
    id = "clip_a",
    track_id = "v1",
    timeline_start = Rational.new(120, 24, 1),
    duration = Rational.new(80, 24, 1)
}

local function time_to_pixel(time_obj, viewport_width)
    -- Treat one frame as one pixel to keep math simple.
    return math.floor(time_obj.frames)
end

local boundary_px = time_to_pixel(clip.timeline_start, 1000)
local roll_zone = (ui_constants.TIMELINE and ui_constants.TIMELINE.ROLL_ZONE_PX) or 7
local center_half = math.max(1, math.floor(roll_zone / 2))

-- Hover slightly inside the gap (left of boundary) -> select gap edge.
local gap_pick = edge_picker.pick_edges({clip}, boundary_px - (center_half + 2), 1000, {
    time_to_pixel = time_to_pixel,
    edge_zone = 10,
    roll_zone = roll_zone
})
assert(gap_pick.roll_used == false, "Gap hover should not trigger roll")
assert(#gap_pick.selection == 1, "Gap hover should pick single edge")
assert(gap_pick.selection[1].edge_type == "gap_before", "Gap hover should select gap_before edge")

-- Hover exactly on the clip boundary -> prefer the clip edge (user grabbing the handle).
local clip_pick = edge_picker.pick_edges({clip}, boundary_px, 1000, {
    time_to_pixel = time_to_pixel,
    edge_zone = 10,
    roll_zone = roll_zone
})
assert(clip_pick.roll_used == false, "Clip-only boundary should not force roll")
assert(#clip_pick.selection == 1, "Clip boundary hover should select single edge")
assert(clip_pick.selection[1].edge_type == "in", "Clip boundary hover should select clip in edge")
assert(clip_pick.selection[1].trim_type == "ripple", "Clip boundary hover must be treated as ripple")

print("✅ Edge picker treats gap boundaries as ripple selections")
