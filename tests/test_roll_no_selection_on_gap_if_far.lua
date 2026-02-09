#!/usr/bin/env luajit

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local roll_detector = require("ui.timeline.roll_detector")

-- Two clips with large gap: no roll selection; only nearest edge should be picked by input logic.
local clips = {
    {id = "a", track_id = "v1", timeline_start = 0, duration = 50},
    {id = "b", track_id = "v1", timeline_start = 200, duration = 50},
}

local width = 1000
local function time_to_px(frames)
    local total_frames = 300
    return math.floor((frames / total_frames) * width + 0.5)
end

local entries = {}
for _, clip in ipairs(clips) do
    local sx = time_to_px(clip.timeline_start)
    local ex = time_to_px(clip.timeline_start + clip.duration)
    table.insert(entries, {clip = clip, edge = "in", distance = 0, px = sx})
    table.insert(entries, {clip = clip, edge = "out", distance = 0, px = ex})
end

local function detect_roll_between_clips(left_clip, right_clip, click_x, viewport_width)
    local left_end = left_clip.timeline_start + left_clip.duration
    local sep = right_clip.timeline_start - left_end
    return sep == 1
end

-- Place cursor near the left clip's out edge; far from roll zone to the right clip.
local x = entries[2].px + 1
local nearby = {}
for _, e in ipairs(entries) do
    e.distance = math.abs(x - e.px)
    table.insert(nearby, e)
end

local sel, pair = roll_detector.find_best_roll_pair(nearby, x, width, detect_roll_between_clips)
assert(sel == nil and pair == nil, "Roll should not be detected with large gap")

print("✅ No roll selection when clips are far apart")
