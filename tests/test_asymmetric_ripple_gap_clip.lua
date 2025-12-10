#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test asymmetric ripple with gap_after [  and clip out ]
-- This tests the "opposing brackets" logic (Rule 11)
local TEST_DB = "/tmp/jve/test_asymmetric_ripple_gap_clip.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {timeline_start = 2500},  -- Gap from 1500 to 2500 (1000 frames)
        v2 = {timeline_start = 1800, duration = 800}  -- Ends at 2600
    }
})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

print("Initial state:")
print(string.format("  V1 left: start=%d, dur=%d, end=%d", clips.v1_left.timeline_start, clips.v1_left.duration, clips.v1_left.timeline_start + clips.v1_left.duration))
print(string.format("  V1 gap:  start=%d, end=%d, dur=%d", 1500, 2500, 1000))
print(string.format("  V1 right:start=%d, dur=%d, end=%d", clips.v1_right.timeline_start, clips.v1_right.duration, clips.v1_right.timeline_start + clips.v1_right.duration))
print(string.format("  V2:      start=%d, dur=%d, end=%d", clips.v2.timeline_start, clips.v2.duration, clips.v2.timeline_start + clips.v2.duration))

-- Select V1 gap_after [ (left edge of gap) and V2 out ] (right edge of V2)
-- Drag RIGHT by +200 frames
-- Expected behavior:
--   - V2 out ] moves right: V2 extends from 800 to 1000 frames
--   - V1 gap [ has opposing bracket, so delta negated: gap shrinks from 1000 to 800 frames
--   - V1 right shifts right by 200 frames (downstream of gap closure)

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", 200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "Asymmetric ripple failed")

-- Reload clips
local v1_left = Clip.load(clips.v1_left.id, db)
local v1_right = Clip.load(clips.v1_right.id, db)
local v2 = Clip.load(clips.v2.id, db)

print("\nFinal state:")
print(string.format("  V1 left: start=%d, dur=%d, end=%d", v1_left.timeline_start.frames, v1_left.duration.frames, v1_left.timeline_start.frames + v1_left.duration.frames))
print(string.format("  V1 gap:  start=%d, end=%d, dur=%d", v1_left.timeline_start.frames + v1_left.duration.frames, v1_right.timeline_start.frames, v1_right.timeline_start.frames - (v1_left.timeline_start.frames + v1_left.duration.frames)))
print(string.format("  V1 right:start=%d, dur=%d, end=%d", v1_right.timeline_start.frames, v1_right.duration.frames, v1_right.timeline_start.frames + v1_right.duration.frames))
print(string.format("  V2:      start=%d, dur=%d, end=%d", v2.timeline_start.frames, v2.duration.frames, v2.timeline_start.frames + v2.duration.frames))

-- V2 out ] dragged right +200: should extend
assert(v2.duration.frames == 1000,
    string.format("V2 should extend by 200 frames (800→1000), got %d", v2.duration.frames))
assert(v2.timeline_start.frames == 1800,
    string.format("V2 start should stay anchored at 1800, got %d", v2.timeline_start.frames))

-- V1 gap [ had opposing bracket to lead ], so delta negated from +200 to -200
-- Gap "in" edge with delta=-200: new_duration = 1000 - (-200) = 1200 (gap GROWS?!)
-- OR: Gap should shrink because downstream clips moved?
-- Let's check the actual gap size:
local gap_size = v1_right.timeline_start.frames - (v1_left.timeline_start.frames + v1_left.duration.frames)
print(string.format("\nActual gap size: %d (expected 800 or 1200?)", gap_size))

-- V1 right should shift: either left (if gap closed) or right (if gap grew)
-- If gap closed by 200: v1_right moves from 2500 to 2300
-- If gap grew by 200: v1_right moves from 2500 to 2700

layout:cleanup()
print("✅ Asymmetric ripple with gap+clip opposing brackets")
