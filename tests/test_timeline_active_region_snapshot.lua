#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local TimelineActiveRegion = require("core.timeline_active_region")

local function clip(id, track_id, start_frames, duration_frames, fps_num, fps_den)
    return {
        id = id,
        track_id = track_id,
        timeline_start = Rational.new(start_frames, fps_num, fps_den),
        duration = Rational.new(duration_frames, fps_num, fps_den),
        source_in = Rational.new(0, fps_num, fps_den),
        source_out = Rational.new(duration_frames, fps_num, fps_den),
        fps_numerator = fps_num,
        fps_denominator = fps_den,
        enabled = 1
    }
end

local fps_num, fps_den = 30, 1
local tracks = {
    {id = "t1"},
    {id = "t2"}
}

local clips_t1 = {
    clip("a", "t1", 0, 100, fps_num, fps_den),
    clip("b", "t1", 900, 50, fps_num, fps_den),
    clip("c", "t1", 1000, 50, fps_num, fps_den),
    clip("d", "t1", 2000, 50, fps_num, fps_den),
}
local clips_t2 = {
    clip("e", "t2", 10, 100, fps_num, fps_den),
    clip("f", "t2", 980, 10, fps_num, fps_den),
    clip("g", "t2", 3000, 10, fps_num, fps_den),
}

local clip_lookup = {}
for _, c in ipairs(clips_t1) do clip_lookup[c.id] = c end
for _, c in ipairs(clips_t2) do clip_lookup[c.id] = c end

local state = {
    get_sequence_frame_rate = function()
        return {fps_numerator = fps_num, fps_denominator = fps_den}
    end,
    get_all_tracks = function()
        return tracks
    end,
    get_track_clip_index = function(track_id)
        if track_id == "t1" then return clips_t1 end
        if track_id == "t2" then return clips_t2 end
        return {}
    end,
    get_clip_by_id = function(id)
        return clip_lookup[id]
    end,
    get_clips = function()
        error("get_clips() must not be used by TimelineActiveRegion", 2)
    end
}

local edges = {
    {clip_id = "c", edge_type = "out", trim_type = "ripple"},
    {clip_id = "f", edge_type = "in", trim_type = "ripple"},
}

local region = TimelineActiveRegion.compute_for_edge_drag(state, edges, {pad_frames = 30})
assert(type(region) == "table", "Expected TimelineActiveRegion.compute_for_edge_drag region table")
assert(region.interaction_start_frames <= 950 and region.interaction_end_frames >= 1050,
    "Region should include edge neighborhood")

local snapshot = TimelineActiveRegion.build_snapshot_for_region(state, region)
assert(type(snapshot) == "table", "Expected snapshot table")
assert(type(snapshot.clip_lookup) == "table", "Expected snapshot.clip_lookup")
assert(type(snapshot.post_boundary_first_clip) == "table", "Expected snapshot.post_boundary_first_clip table")
assert(type(snapshot.post_boundary_prev_clip) == "table", "Expected snapshot.post_boundary_prev_clip table")

-- With pad_frames=30 around the 980..1050 neighborhood:
-- - include c(1000) and f(980), plus boundary clips needed for clamping/bulk-shift planning.
assert(snapshot.clip_lookup.c, "Expected clip c in snapshot")
assert(snapshot.clip_lookup.f, "Expected clip f in snapshot")
assert(not snapshot.clip_lookup.a, "Did not expect clip a in snapshot")
assert(snapshot.clip_lookup.d, "Expected clip d in snapshot (post-boundary anchor)")
assert(snapshot.clip_lookup.g, "Expected clip g in snapshot (post-boundary anchor)")

-- Post-boundary clips are tracked per-track (for bulk shift planning).
assert(snapshot.post_boundary_first_clip.t1 == "d", "Expected t1 post-boundary clip to be d")
assert(snapshot.post_boundary_prev_clip.t1 == "c", "Expected t1 post-boundary predecessor to be c")
assert(snapshot.post_boundary_first_clip.t2 == "g", "Expected t2 post-boundary clip to be g")
assert(snapshot.post_boundary_prev_clip.t2 == "f", "Expected t2 post-boundary predecessor to be f")

print("✅ TimelineActiveRegion snapshot scopes clips without get_clips()")
