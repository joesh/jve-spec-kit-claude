#!/usr/bin/env luajit

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./src/lua/?.lua"
    .. ";./src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

local edge_picker = require("ui.timeline.edge_picker")
local ui_constants = require("core.ui_constants")

local EDGE = ui_constants.TIMELINE.EDGE_ZONE_PX
local ROLL = ui_constants.TIMELINE.ROLL_ZONE_PX or EDGE
local ROLL_RADIUS = ROLL / 2

local function make_clip(id, start_frames, dur_frames)
    return {
        id = id,
        track_id = "v1",
        timeline_start = start_frames,
        duration = dur_frames
    }
end

local function time_to_pixel(time_obj)
    return time_obj
end

local function pick(clips, x)
    return edge_picker.pick_edges(clips, x, 2000, {
        edge_zone = EDGE,
        roll_zone = ROLL,
        time_to_pixel = function(t) return time_to_pixel(t) end
    })
end

-- Adjacent clips: left zone hits left edge, center rolls, right zone hits right edge.
do
    local a = make_clip("a", 0, 100)
    local b = make_clip("b", 100, 80)
    local boundary = 100

    local left_zone = pick({a, b}, boundary - (ROLL_RADIUS + 2))
    assert(left_zone.roll_used == false, "left zone should not roll")
    assert(left_zone.selection[1].edge_type == "out" and left_zone.selection[1].clip_id == "a", "left zone should pick left clip out edge")

    local center = pick({a, b}, boundary)
    assert(center.roll_used == true, "center zone should roll")
    assert(#center.selection == 2, "center roll should select both edges")

    local right_zone = pick({a, b}, boundary + (ROLL_RADIUS + 2))
    assert(right_zone.roll_used == false, "right zone should not roll")
    assert(right_zone.selection[1].edge_type == "in" and right_zone.selection[1].clip_id == "b", "right zone should pick right clip in edge")
end

-- Gap/clip boundary: no roll because only one real clip is available.
do
    local clip = make_clip("solo", 200, 50)
    local boundary = 200

    local left_side = pick({clip}, boundary - (ROLL_RADIUS + 2))
    assert(left_side.roll_used == false, "gap left zone should not roll")
    assert(left_side.selection[1].edge_type == "gap_before", "gap left zone should select gap_before edge")

    local center = pick({clip}, boundary)
    assert(center.roll_used == true, "gap/clip center should roll with the neighboring gap")
    assert(#center.selection == 2, "gap/clip center should select both edges for roll")
    local gap_seen, clip_seen = false, false
    for _, entry in ipairs(center.selection) do
        if entry.edge_type == "gap_before" then gap_seen = true end
        if entry.edge_type == "in" then clip_seen = true end
    end
    assert(gap_seen and clip_seen, "gap/clip center roll should include both edges")

    local right_side = pick({clip}, boundary + (ROLL_RADIUS + 2))
    assert(right_side.roll_used == false, "gap right zone should not roll")
    assert(right_side.selection[1].edge_type == "in", "gap right zone should select clip in edge")
end

print("✅ Edge picker gap/clip zones behave correctly")
