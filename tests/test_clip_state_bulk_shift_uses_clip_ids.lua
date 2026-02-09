#!/usr/bin/env luajit

-- Regression: clip_state bulk shifts must respect explicit clip_ids (the
-- authoritative set captured during DB apply) instead of shifting everything
-- at/after the anchor start time.

require("test_env")

local Rational = require("core.rational")
local data = require("ui.timeline.state.timeline_state_data")
local clip_state = require("ui.timeline.state.clip_state")

data.reset()
data.state.sequence_frame_rate = { fps_numerator = 25, fps_denominator = 1 }

data.state.tracks = {
    { id = "v1", track_type = "VIDEO" },
}

local function clip(id, start_frames)
    return {
        id = id,
        track_id = "v1",
        timeline_start = start_frames,
        duration = 10,
        enabled = true,
    }
end

data.state.clips = {
    clip("clip_a", 0),
    clip("clip_b", 1000),
    clip("clip_c", 2000),
    clip("clip_d", 3000),
}

clip_state.invalidate_indexes()

local mutations = {
    bulk_shifts = {
        {
            track_id = "v1",
            first_clip_id = "clip_b",
            shift_frames = -100,
            clip_ids = { "clip_b", "clip_c" },
        },
    },
}

clip_state.apply_mutations(mutations)

assert(clip_state.get_by_id("clip_a").timeline_start == 0, "bulk_shift should not move clip_a")
assert(clip_state.get_by_id("clip_b").timeline_start == 900, "bulk_shift should move clip_b")
assert(clip_state.get_by_id("clip_c").timeline_start == 1900, "bulk_shift should move clip_c")
assert(clip_state.get_by_id("clip_d").timeline_start == 3000, "bulk_shift must respect clip_ids and not move clip_d")

local undo = {
    bulk_shifts = {
        {
            track_id = "v1",
            first_clip_id = "clip_b",
            shift_frames = 100,
            clip_ids = { "clip_b", "clip_c" },
        },
    },
}

clip_state.apply_mutations(undo)

assert(clip_state.get_by_id("clip_a").timeline_start == 0, "undo should restore clip_a")
assert(clip_state.get_by_id("clip_b").timeline_start == 1000, "undo should restore clip_b")
assert(clip_state.get_by_id("clip_c").timeline_start == 2000, "undo should restore clip_c")
assert(clip_state.get_by_id("clip_d").timeline_start == 3000, "undo should not move clip_d")

print("✅ clip_state bulk_shift honors clip_ids")

