#!/usr/bin/env luajit
-- Regression: get_all should hydrate clip timeline_start/duration to Rational before returning.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local clip_state = require("ui.timeline.state.clip_state")
local data = require("ui.timeline.state.timeline_state_data")
local Rational = require("core.rational")

data.reset()
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.clips = {
    {
        id = "c1",
        track_id = "v1",
        timeline_start = {frames = 0, fps_numerator = 24, fps_denominator = 1},
        duration = {frames = 48, fps_numerator = 24, fps_denominator = 1},
        enabled = true,
    }
}

local clips = clip_state.get_all()
assert(#clips == 1, "expected one clip")
local clip = clips[1]
assert(getmetatable(clip.timeline_start) == Rational.metatable, "timeline_start not Rational from get_all")
assert(getmetatable(clip.duration) == Rational.metatable, "duration not Rational from get_all")

print("✅ clip_state.get_all hydrates clip bounds")
