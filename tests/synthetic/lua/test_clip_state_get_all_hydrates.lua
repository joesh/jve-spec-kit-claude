#!/usr/bin/env luajit
-- Regression: get_all should return clips with integer sequence_start/duration.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local clip_state = require("ui.timeline.state.clip_state")
local data = require("ui.timeline.state.timeline_state_data")
local test_env = require("test_env")

data.reset()
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
local cache = test_env.install_displayed_tab_stub()
cache.clips = {
    {
        id = "c1",
        track_id = "v1",
        sequence_start = 0,
        duration = 48,
        enabled = true,
    }
}
cache.invalidate()

local clips = clip_state.get_all()
assert(#clips == 1, "expected one clip")
local clip = clips[1]
assert(type(clip.sequence_start) == "number", "sequence_start should be integer")
assert(type(clip.duration) == "number", "duration should be integer")
assert(clip.sequence_start == 0, "sequence_start should be 0")
assert(clip.duration == 48, "duration should be 48")

print("✅ clip_state.get_all returns integer clip bounds")
