#!/usr/bin/env luajit

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local roll_detector = require("ui.timeline.roll_detector")
local Rational = require("core.rational")

-- Two clips on the same track with a gap between them; roll should NOT be detected.
local clips = {
    {id = "a", track_id = "v1", timeline_start = Rational.new(0,24,1), duration = Rational.new(100,24,1)},
    {id = "b", track_id = "v1", timeline_start = Rational.new(120,24,1), duration = Rational.new(80,24,1)}, -- 20-frame gap
}

local width = 1000
local function time_to_px(rat)
    local total_frames = 300
    return math.floor((rat.frames / total_frames) * width + 0.5)
end

local entries = {}
for _, clip in ipairs(clips) do
    local sx = time_to_px(clip.timeline_start)
    local ex = time_to_px(clip.timeline_start + clip.duration)
    table.insert(entries, {clip = clip, edge = "in", distance = 0, px = sx})
    table.insert(entries, {clip = clip, edge = "out", distance = 0, px = ex})
end

local function detect_roll_between_clips(left_clip, right_clip, click_x, viewport_width)
    -- Mirror timeline_state.detect_roll_between_clips adjacency rule
    local boundary_left = left_clip.timeline_start + left_clip.duration
    local boundary_right = right_clip.timeline_start
    if boundary_left ~= boundary_right then
        return false
    end
    return true
end

-- Place cursor midway between boundaries (inside any roll/edge zones)
local boundary_mid_px = (entries[3].px + entries[4].px) / 2
local nearby = {}
for _, e in ipairs(entries) do
    e.distance = math.abs(boundary_mid_px - e.px)
    table.insert(nearby, e)
end

local sel, pair = roll_detector.find_best_roll_pair(nearby, boundary_mid_px, width, detect_roll_between_clips)
assert(sel == nil and pair == nil, "Roll should not be detected when clips are separated by a gap")

print("✅ Roll not detected across gaps")
