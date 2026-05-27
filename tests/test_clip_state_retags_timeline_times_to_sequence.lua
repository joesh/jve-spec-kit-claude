#!/usr/bin/env luajit

-- Regression: clip_state should preserve integer sequence_start/duration values.
-- With the integer refactor, no retagging is needed - coords are plain integers.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local data = require("ui.timeline.state.timeline_state_data")
local clip_state = require("ui.timeline.state.clip_state")
local test_env = require("test_env")

data.reset()
data.state.sequence_frame_rate = { fps_numerator = 25, fps_denominator = 1 }

local cache = test_env.install_displayed_tab_stub()
cache.tracks = {
    { id = "v1", track_type = "VIDEO" },
}

-- Clips use plain integer frames
cache.clips = {
    {
        id = "c1",
        track_id = "v1",
        sequence_start = 1500,
        duration = 100,
        source_in = 0,
        source_out = 100,
        enabled = true,
    },
}

cache.invalidate()
local indexed = clip_state.get_track_clip_index("v1")
assert(indexed and #indexed == 1, "expected one indexed clip")

local clip = indexed[1]
assert(type(clip.sequence_start) == "number", "sequence_start should be integer")
assert(type(clip.duration) == "number", "duration should be integer")
assert(clip.sequence_start == 1500, "expected sequence_start preserved as 1500")
assert(clip.duration == 100, "expected duration preserved as 100")

print("✅ clip_state preserves integer timeline times")
