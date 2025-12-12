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

-- Hover exactly on the clip boundary -> treat as roll between gap and clip.
local clip_pick = edge_picker.pick_edges({clip}, boundary_px, 1000, {
    time_to_pixel = time_to_pixel,
    edge_zone = 10,
    roll_zone = roll_zone
})
assert(clip_pick.roll_used == true, "Clip + gap boundary should allow roll selection")
assert(#clip_pick.selection == 2, "Roll boundary hover should select both edges")
local seen_gap = false
local seen_clip = false
for _, entry in ipairs(clip_pick.selection) do
    if entry.edge_type == "gap_before" then
        seen_gap = true
    elseif entry.edge_type == "in" then
        seen_clip = true
    end
    assert(entry.trim_type == "roll", "Roll boundary hover must mark entries as roll")
end
assert(seen_gap, "Roll boundary hover should include the gap edge")
assert(seen_clip, "Roll boundary hover should include the clip edge")

print("✅ Edge picker prefers ripple when off-center and roll in the center zone")
