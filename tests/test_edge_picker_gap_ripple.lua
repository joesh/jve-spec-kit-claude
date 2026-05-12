#!/usr/bin/env luajit

-- Regression: picking an edge where a gap clip is adjacent should not force
-- a roll selection. When hovering off-center, only the gap's or clip's edge
-- is selected (ripple). Center zone allows roll between gap and clip.
-- (Updated for gap-as-clip: gaps are real clips in the track list.)

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local edge_picker = require("ui.timeline.edge_picker")
local ui_constants = require("core.ui_constants")

local gap_clip = {
    id = "gap_v1_0",
    track_id = "v1",
    timeline_start = 0,
    duration = 120,
    clip_kind = "gap"
}

local clip = {
    id = "clip_a",
    track_id = "v1",
    timeline_start = 120,
    duration = 80,
    clip_kind = "sequence"
}

local track_clips = {gap_clip, clip}

local function time_to_pixel(time_obj, _viewport_width)
    return math.floor(time_obj)
end

local boundary_px = time_to_pixel(clip.timeline_start, 1000)
local roll_zone = (ui_constants.TIMELINE and ui_constants.TIMELINE.ROLL_ZONE_PX) or 7
local center_half = math.max(1, math.floor(roll_zone / 2))

-- Hover slightly inside the gap (left of boundary) -> select gap's out edge (ripple).
local gap_pick = edge_picker.pick_edges(track_clips, boundary_px - (center_half + 2), 1000, {
    time_to_pixel = time_to_pixel,
    edge_zone = 10,
    roll_zone = roll_zone
})
assert(gap_pick.roll_used == false, "Gap hover should not trigger roll")
assert(#gap_pick.selection == 1, "Gap hover should pick single edge")
assert(gap_pick.selection[1].edge_type == "out", "Gap hover should select gap's out edge")
assert(gap_pick.selection[1].clip_id == "gap_v1_0", "Gap hover should reference gap clip")

-- Hover exactly on the clip boundary -> treat as roll between gap:out and clip:in.
local clip_pick = edge_picker.pick_edges(track_clips, boundary_px, 1000, {
    time_to_pixel = time_to_pixel,
    edge_zone = 10,
    roll_zone = roll_zone
})
assert(clip_pick.roll_used == true, "Clip + gap boundary should allow roll selection")
assert(#clip_pick.selection == 2, "Roll boundary hover should select both edges")
local seen_gap = false
local seen_clip = false
for _, entry in ipairs(clip_pick.selection) do
    if entry.clip_id == "gap_v1_0" and entry.edge_type == "out" then
        seen_gap = true
    elseif entry.clip_id == "clip_a" and entry.edge_type == "in" then
        seen_clip = true
    end
    assert(entry.trim_type == "roll", "Roll boundary hover must mark entries as roll")
end
assert(seen_gap, "Roll boundary hover should include the gap's out edge")
assert(seen_clip, "Roll boundary hover should include the clip's in edge")

print("✅ Edge picker prefers ripple when off-center and roll in the center zone")
