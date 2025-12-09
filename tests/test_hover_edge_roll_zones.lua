#!/usr/bin/env luajit

-- Integration-ish: Hover zones should select left edge, roll pair, or right edge depending on cursor x.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local ui_constants = require("core.ui_constants")
local edge_utils = require("ui.timeline.edge_utils")
local roll_detector = require("ui.timeline.roll_detector")
local Rational = require("core.rational")

-- Build a tiny viewport with two adjacent clips
local clips = {
    {
        id = "a",
        track_id = "v1",
        timeline_start = Rational.new(0, 24, 1),
        duration = Rational.new(100, 24, 1)
    },
    {
        id = "b",
        track_id = "v1",
        timeline_start = Rational.new(100, 24, 1),
        duration = Rational.new(80, 24, 1)
    }
}

-- Compute pixel positions given a fake viewport width
local width = 1000
local function time_to_px(rat)
    local total_frames = 200
    return math.floor((rat.frames / total_frames) * width + 0.5)
end

-- Build entries as timeline_view_input would
local function build_entries()
    local entries = {}
    for _, clip in ipairs(clips) do
        local sx = time_to_px(clip.timeline_start)
        local ex = time_to_px(clip.timeline_start + clip.duration)
        table.insert(entries, {clip = clip, edge = "in", distance = 0, px = sx})
        table.insert(entries, {clip = clip, edge = "out", distance = 0, px = ex})
    end
    return entries
end

local entries = build_entries()
table.sort(entries, function(a,b) return a.px < b.px end)
local EDGE = ui_constants.TIMELINE.EDGE_ZONE_PX
local ROLL = ui_constants.TIMELINE.ROLL_ZONE_PX

local boundary_px = entries[3].px -- boundary between a.out and b.in
local search_radius = math.max(EDGE, ROLL) + 2

local function detect_roll_between_clips(left_clip, right_clip, click_x, viewport_width)
    -- Mirror timeline_state.detect_roll_between_clips
    local EDGE = ui_constants.TIMELINE.ROLL_ZONE_PX
    local sx = time_to_px(left_clip.timeline_start + left_clip.duration)
    local ex = time_to_px(right_clip.timeline_start)
    if ex - sx < EDGE then
        local mid = (sx + ex) / 2
        if math.abs(click_x - mid) <= EDGE / 2 then
            return true
        end
    end
    return false
end

local function run_at(x)
    local nearby = {}
    for _, e in ipairs(entries) do
        local dist = math.abs(x - e.px)
        if dist <= search_radius then
            local copy = {clip = e.clip, edge = e.edge, distance = dist}
            table.insert(nearby, copy)
        end
    end
    local sel, pair = roll_detector.find_best_roll_pair(nearby, x, width, detect_roll_between_clips)
    return nearby, sel, pair
end

-- Left edge zone: select only left edge
do
    local x = boundary_px - EDGE - 2
    local nearby, sel, pair = run_at(x)
    assert(sel == nil, "Should not roll in left edge zone")
    assert(#nearby >= 1, "expected at least one edge nearby")
    local has_left = false
    for _, e in ipairs(nearby) do
        if e.edge == "out" and e.clip.id == "a" then has_left = true end
    end
    assert(has_left, "expected to include left clip out edge")
end

-- Middle roll zone: select both edges
do
    local x = boundary_px
    local nearby, sel, pair = run_at(x)
    assert(sel and #sel == 2, "expected roll selection in middle zone")
    assert(pair and pair.roll_kind == "clip_clip", "expected clip_clip roll pair")
end

-- Right edge zone: select only right edge
do
    local x = boundary_px + EDGE + 2
    local nearby, sel, pair = run_at(x)
    assert(sel == nil, "Should not roll in right edge zone")
    local hit = false
    for _, e in ipairs(nearby) do
        if e.edge == "in" and e.clip.id == "b" then hit = true end
    end
    assert(hit, "expected to hit right clip in edge")
end

print("✅ Hover edge/roll zones behave correctly")
