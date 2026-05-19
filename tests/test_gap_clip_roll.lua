#!/usr/bin/env luajit

-- TDD tests for clip-gap roll with gap as a real clip in the track list.
-- Tests that BatchRippleEdit handles gap clips correctly when the gap-as-clip
-- refactor is complete. Must FAIL until the refactor is done.
--
-- Uses ripple_layout helper to create test layouts, then manually inserts
-- gap clips into the track to simulate the gap-as-clip model.

require("test_env")

local ripple_layout = require("helpers.ripple_layout")
local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local gap_lifecycle = require("core.gap_lifecycle")

local SEQ_FPS = { fps_numerator = 1000, fps_denominator = 1 }

-- (a) roll right into gap → clip extends, gap shrinks, downstream stays
print("--- (a) roll right into gap → clip extends, gap shrinks ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left", "v1_right"},
            v1_left = { sequence_start = 0, duration = 1000, source_in = 500 },
            v1_right = { sequence_start = 2000, duration = 1000, source_in = 500 },
        }
    })

    -- Compute gaps for the track
    local clips_on_track = {
        { id = "clip_v1_left", track_id = "track_v1", sequence_start = 0, duration = 1000,
          clip_kind = "sequence", media_id = "media_primary" },
        { id = "clip_v1_right", track_id = "track_v1", sequence_start = 2000, duration = 1000,
          clip_kind = "sequence", media_id = "media_primary" },
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("track_v1", clips_on_track, SEQ_FPS)
    assert(#gaps == 1, string.format("expected 1 gap, got %d", #gaps))
    assert(gaps[1].sequence_start == 1000, "gap should start at 1000")
    assert(gaps[1].duration == 1000, "gap should be 1000 frames")

    -- Roll: clip_v1_left:out + gap:in, delta = +200 (extend clip into gap)
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        { clip_id = "clip_v1_left", edge_type = "out", trim_type = "roll" },
        { clip_id = gaps[1].id, edge_type = "in", trim_type = "roll" },
    })
    cmd:set_parameter("delta_frames", 200)

    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok = executor(cmd)
    assert(ok, "BatchRippleEdit roll into gap should succeed")

    local left = Clip.load("clip_v1_left")
    local right = Clip.load("clip_v1_right")
    assert(left.duration == 1200, string.format("left clip duration=%d, expected 1200", left.duration))
    assert(right.sequence_start == 2000, string.format("right clip should stay at 2000, got %d", right.sequence_start))

    layout:cleanup()
end

-- (b) roll left → clip shrinks, gap grows, downstream stays
print("--- (b) roll left → clip shrinks, gap grows ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left", "v1_right"},
            v1_left = { sequence_start = 0, duration = 1000, source_in = 500 },
            v1_right = { sequence_start = 2000, duration = 1000, source_in = 500 },
        }
    })

    local clips_on_track = {
        { id = "clip_v1_left", track_id = "track_v1", sequence_start = 0, duration = 1000,
          clip_kind = "sequence", media_id = "media_primary" },
        { id = "clip_v1_right", track_id = "track_v1", sequence_start = 2000, duration = 1000,
          clip_kind = "sequence", media_id = "media_primary" },
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("track_v1", clips_on_track, SEQ_FPS)
    assert(#gaps == 1, "expected 1 gap")

    -- Roll: clip_v1_left:out + gap:in, delta = -200 (shrink clip, grow gap)
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        { clip_id = "clip_v1_left", edge_type = "out", trim_type = "roll" },
        { clip_id = gaps[1].id, edge_type = "in", trim_type = "roll" },
    })
    cmd:set_parameter("delta_frames", -200)

    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok = executor(cmd)
    assert(ok, "BatchRippleEdit roll shrink should succeed")

    local left = Clip.load("clip_v1_left")
    local right = Clip.load("clip_v1_right")
    assert(left.duration == 800, string.format("left clip duration=%d, expected 800", left.duration))
    assert(right.sequence_start == 2000, string.format("right clip should stay at 2000, got %d", right.sequence_start))

    layout:cleanup()
end

-- (c) roll to consume entire gap → gap deleted, clips adjacent
print("--- (c) roll to consume entire gap ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left", "v1_right"},
            v1_left = { sequence_start = 0, duration = 1000, source_in = 500 },
            v1_right = { sequence_start = 1500, duration = 1000, source_in = 500 },
        }
    })

    local clips_on_track = {
        { id = "clip_v1_left", track_id = "track_v1", sequence_start = 0, duration = 1000,
          clip_kind = "sequence", media_id = "media_primary" },
        { id = "clip_v1_right", track_id = "track_v1", sequence_start = 1500, duration = 1000,
          clip_kind = "sequence", media_id = "media_primary" },
    }
    local gaps = gap_lifecycle.compute_gaps_for_track("track_v1", clips_on_track, SEQ_FPS)
    assert(#gaps == 1, "expected 1 gap")
    assert(gaps[1].duration == 500, "gap should be 500 frames")

    -- Roll: consume entire 500-frame gap
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        { clip_id = "clip_v1_left", edge_type = "out", trim_type = "roll" },
        { clip_id = gaps[1].id, edge_type = "in", trim_type = "roll" },
    })
    cmd:set_parameter("delta_frames", 500)

    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok = executor(cmd)
    assert(ok, "BatchRippleEdit consume gap should succeed")

    local left = Clip.load("clip_v1_left")
    local right = Clip.load("clip_v1_right")
    assert(left.duration == 1500, string.format("left clip duration=%d, expected 1500", left.duration))
    assert(right.sequence_start == 1500, string.format("right clip should stay at 1500, got %d", right.sequence_start))

    layout:cleanup()
end

print("✅ test_gap_clip_roll.lua passed")
