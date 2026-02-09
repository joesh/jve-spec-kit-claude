#!/usr/bin/env luajit

-- Regression: clip_state should preserve integer timeline_start/duration values.
-- With the integer refactor, no retagging is needed - coords are plain integers.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local data = require("ui.timeline.state.timeline_state_data")
local clip_state = require("ui.timeline.state.clip_state")

data.reset()
data.state.sequence_frame_rate = { fps_numerator = 25, fps_denominator = 1 }

data.state.tracks = {
    { id = "v1", track_type = "VIDEO" },
}

-- Clips use plain integer frames
data.state.clips = {
    {
        id = "c1",
        track_id = "v1",
        timeline_start = 1500,
        duration = 100,
        source_in = 0,
        source_out = 100,
        enabled = true,
    },
}

clip_state.invalidate_indexes()
local indexed = clip_state.get_track_clip_index("v1")
assert(indexed and #indexed == 1, "expected one indexed clip")

local clip = indexed[1]
assert(type(clip.timeline_start) == "number", "timeline_start should be integer")
assert(type(clip.duration) == "number", "duration should be integer")
assert(clip.timeline_start == 1500, "expected timeline_start preserved as 1500")
assert(clip.duration == 100, "expected duration preserved as 100")

print("✅ clip_state preserves integer timeline times")
