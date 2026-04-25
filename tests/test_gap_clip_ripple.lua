#!/usr/bin/env luajit

-- TDD tests for multitrack ripple with gap clips in track list.
-- Must FAIL until the gap-as-clip refactor is complete.

require("test_env")

local ripple_layout = require("helpers.ripple_layout")
local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local gap_lifecycle = require("core.gap_lifecycle")

local SEQ_FPS = { fps_numerator = 1000, fps_denominator = 1 }

-- (a) ripple shrink on V1 with gap on A1 → gap absorbs shift on A1
print("--- (a) ripple shrink V1, gap absorbs on A1 ---")
do
    local layout = ripple_layout.create({
        tracks = {
            order = {"v1", "a1"},
            a1 = { track_type = "AUDIO", track_index = 2 },
        },
        clips = {
            order = {"v1_left", "v1_right", "a1_left", "a1_right"},
            v1_left = { timeline_start = 0, duration = 1000, source_in = 500 },
            v1_right = { timeline_start = 1000, duration = 1000, source_in = 500 },
            a1_left = { id = "clip_a1_left", track_key = "a1", timeline_start = 0, duration = 1000, source_in = 500 },
            a1_right = { id = "clip_a1_right", track_key = "a1", timeline_start = 2000, duration = 1000, source_in = 500 },
        }
    })

    -- A1 has a gap [1000..2000]
    local a1_clips = {
        { id = "clip_a1_left", track_id = "track_a1", timeline_start = 0, duration = 1000,
          clip_kind = "nested", media_id = "media_primary" },
        { id = "clip_a1_right", track_id = "track_a1", timeline_start = 2000, duration = 1000,
          clip_kind = "nested", media_id = "media_primary" },
    }
    local a1_gaps = gap_lifecycle.compute_gaps_for_track("track_a1", a1_clips, SEQ_FPS)
    assert(#a1_gaps == 1, "A1 should have 1 gap")
    assert(a1_gaps[1].duration == 1000, "A1 gap should be 1000 frames")

    -- Ripple: shrink v1_left out edge by 200 → downstream shifts left by 200
    -- On A1, the gap should absorb the shift (shrink by 200)
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        { clip_id = "clip_v1_left", edge_type = "out", trim_type = "ripple" },
    })
    cmd:set_parameter("delta_frames", -200)

    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok = executor(cmd)
    assert(ok, "Multitrack ripple should succeed")

    local v1_left = Clip.load("clip_v1_left")
    local v1_right = Clip.load("clip_v1_right")
    local a1_right = Clip.load("clip_a1_right")

    assert(v1_left.duration == 800, string.format("v1_left duration=%d, expected 800", v1_left.duration))
    assert(v1_right.timeline_start == 800, string.format("v1_right start=%d, expected 800", v1_right.timeline_start))
    -- A1 right clip should shift left by 200 (gap absorbs)
    assert(a1_right.timeline_start == 1800, string.format("a1_right start=%d, expected 1800", a1_right.timeline_start))

    layout:cleanup()
end

-- (b) ripple shrink on V1 with no gap on A1 (adjacent clips) → operation blocked
print("--- (b) ripple shrink V1, adjacent A1 → blocked ---")
do
    local layout = ripple_layout.create({
        tracks = {
            order = {"v1", "a1"},
            a1 = { track_type = "AUDIO", track_index = 2 },
        },
        clips = {
            order = {"v1_left", "v1_right", "a1_left", "a1_right"},
            v1_left = { timeline_start = 0, duration = 1000, source_in = 500 },
            v1_right = { timeline_start = 1000, duration = 1000, source_in = 500 },
            a1_left = { id = "clip_a1_left", track_key = "a1", timeline_start = 0, duration = 1000, source_in = 500 },
            a1_right = { id = "clip_a1_right", track_key = "a1", timeline_start = 1000, duration = 1000, source_in = 500 },
        }
    })

    -- A1 clips are adjacent (no gap) — ripple should be blocked
    -- Dry run to check if blocked (clamped to 0)
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        { clip_id = "clip_v1_left", edge_type = "out", trim_type = "ripple" },
    })
    cmd:set_parameter("delta_frames", -200)
    cmd:set_parameter("dry_run", true)

    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok, payload = executor(cmd)
    assert(ok, "Dry run should succeed")
    -- The clamped delta should be 0 (blocked by adjacent clips on A1)
    assert(payload.clamped_delta_frames == 0,
        string.format("should be blocked (clamped to 0), got clamped_delta_frames=%s",
            tostring(payload.clamped_delta_frames)))

    layout:cleanup()
end

-- (c) ripple extend on V1 → implied zero-length gap on A1, downstream shifts
print("--- (c) ripple extend V1 → implied gap on A1, downstream shifts ---")
do
    local layout = ripple_layout.create({
        tracks = {
            order = {"v1", "a1"},
            a1 = { track_type = "AUDIO", track_index = 2 },
        },
        clips = {
            order = {"v1_left", "v1_right", "a1_left", "a1_right"},
            v1_left = { timeline_start = 0, duration = 1000, source_in = 500 },
            v1_right = { timeline_start = 1000, duration = 1000, source_in = 500 },
            a1_left = { id = "clip_a1_left", track_key = "a1", timeline_start = 0, duration = 1000, source_in = 500 },
            a1_right = { id = "clip_a1_right", track_key = "a1", timeline_start = 1000, duration = 1000, source_in = 500 },
        }
    })

    -- Ripple extend v1_left out edge by +200 → downstream shifts right by 200
    -- A1 clips should also shift right by 200
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        { clip_id = "clip_v1_left", edge_type = "out", trim_type = "ripple" },
    })
    cmd:set_parameter("delta_frames", 200)

    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok = executor(cmd)
    assert(ok, "Multitrack ripple extend should succeed")

    local v1_left = Clip.load("clip_v1_left")
    local v1_right = Clip.load("clip_v1_right")
    local a1_right = Clip.load("clip_a1_right")

    assert(v1_left.duration == 1200, string.format("v1_left duration=%d, expected 1200", v1_left.duration))
    assert(v1_right.timeline_start == 1200, string.format("v1_right start=%d, expected 1200", v1_right.timeline_start))
    -- A1 right should shift right by 200
    assert(a1_right.timeline_start == 1200, string.format("a1_right start=%d, expected 1200", a1_right.timeline_start))

    layout:cleanup()
end

print("✅ test_gap_clip_ripple.lua passed")
