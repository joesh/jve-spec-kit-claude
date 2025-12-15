#!/usr/bin/env luajit

-- Regression: clip_state must normalize timeline_start/duration to the owning
-- sequence timebase so that frame-based indices and viewport culling remain valid.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local Rational = require("core.rational")
local data = require("ui.timeline.state.timeline_state_data")
local clip_state = require("ui.timeline.state.clip_state")

data.reset()
data.state.sequence_frame_rate = { fps_numerator = 25, fps_denominator = 1 }

data.state.tracks = {
    { id = "v1", track_type = "VIDEO" },
}

-- Simulate legacy/misaligned clip rationals: frames are in sequence frames,
-- but the Rational objects are tagged with a different fps.
data.state.clips = {
    {
        id = "c1",
        track_id = "v1",
        timeline_start = Rational.new(1500, 30000, 1001),
        duration = Rational.new(100, 30000, 1001),
        source_in = Rational.new(0, 30000, 1001),
        source_out = Rational.new(100, 30000, 1001),
        enabled = true,
    },
}

clip_state.invalidate_indexes()
local indexed = clip_state.get_track_clip_index("v1")
assert(indexed and #indexed == 1, "expected one indexed clip")

local clip = indexed[1]
assert(clip.timeline_start.fps_numerator == 25 and clip.timeline_start.fps_denominator == 1,
    "expected timeline_start retagged to sequence fps 25/1")
assert(clip.duration.fps_numerator == 25 and clip.duration.fps_denominator == 1,
    "expected duration retagged to sequence fps 25/1")
assert(clip.timeline_start.frames == 1500, "expected timeline_start.frames preserved")
assert(clip.duration.frames == 100, "expected duration.frames preserved")

print("✅ clip_state retags timeline times to sequence fps")

