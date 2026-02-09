#!/usr/bin/env luajit
-- Regression: get_all should return clips with integer timeline_start/duration.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local clip_state = require("ui.timeline.state.clip_state")
local data = require("ui.timeline.state.timeline_state_data")

data.reset()
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.clips = {
    {
        id = "c1",
        track_id = "v1",
        timeline_start = 0,
        duration = 48,
        enabled = true,
    }
}

local clips = clip_state.get_all()
assert(#clips == 1, "expected one clip")
local clip = clips[1]
assert(type(clip.timeline_start) == "number", "timeline_start should be integer")
assert(type(clip.duration) == "number", "duration should be integer")
assert(clip.timeline_start == 0, "timeline_start should be 0")
assert(clip.duration == 48, "duration should be 48")

print("✅ clip_state.get_all returns integer clip bounds")
