#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

--[[
BUG: Opposing brackets logic (lines 782-787) negates delta for ALL edges with opposing brackets,
but it should ONLY negate for edges that form an EDIT POINT (adjacent clips, same track, touching boundaries).

In this test:
- V2 out ] at t=2600 (lead edge)
- V1 gap_after [ at t=1500 (NOT adjacent to V2, different track)

When dragging right +200:
- V2 should extend by 200 (correct)
- V1 gap should ALSO close by 200 (both move same direction for multi-track trim)
- But currently: V1 gap GROWS by 200 because delta gets negated (incorrect!)

Expected behavior (professional NLE):
- Multi-track trim applies SAME delta to all edges (no negation)
- Opposing bracket negation ONLY for edit points (adjacent clips on same track)
]]--

local TEST_DB = "/tmp/jve/test_opposing_brackets_bug.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {timeline_start = 2500},  -- Gap from 1500-2500
        v2 = {timeline_start = 1800, duration = 800}  -- Ends at 2600, NOT adjacent to V1 gap
    }
})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

print("BEFORE:")
print(string.format("  V1 gap:  1500-2500 (1000 frames)"))
print(string.format("  V2:      1800-2600 (800 frames)"))

-- Drag right +200 with V2 out ] as lead
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", 200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "Command failed")

local v1_left = Clip.load(clips.v1_left.id, db)
local v1_right = Clip.load(clips.v1_right.id, db)
local v2 = Clip.load(clips.v2.id, db)

local gap_size = v1_right.timeline_start.frames - (v1_left.timeline_start.frames + v1_left.duration.frames)

print("\nAFTER:")
print(string.format("  V1 gap:  %d-%d (%d frames)",
    v1_left.timeline_start.frames + v1_left.duration.frames,
    v1_right.timeline_start.frames,
    gap_size))
print(string.format("  V2:      %d-%d (%d frames)",
    v2.timeline_start.frames,
    v2.timeline_start.frames + v2.duration.frames,
    v2.duration.frames))

assert(v2.duration.frames == 1000,
    string.format("V2 should extend by 200 (800→1000), got %d", v2.duration.frames))

-- Cross-track edges share the lead delta sign, so dragging right opens the upstream gap.
local expected_gap = 1200
assert(gap_size == expected_gap,
    string.format("Gap should open by 200 (expected %d, got %d)", expected_gap, gap_size))
assert(v1_right.timeline_start.frames == 2700,
    string.format("Downstream clip should shift right to 2700, got %d", v1_right.timeline_start.frames))
print("✅ Multi-track opposing brackets open upstream gaps when dragging right")

layout:cleanup()

-- Additional regression: dragging left should close the gap.
local layout_close = ripple_layout.create({
    db_path = "/tmp/jve/test_opposing_brackets_bug_close.db",
    clips = {
        v1_right = {timeline_start = 2500},
        v2 = {timeline_start = 1800, duration = 800}
    }
})
local db_close = layout_close.db
local clips_close = layout_close.clips
local tracks_close = layout_close.tracks

local cmd_close = Command.create("BatchRippleEdit", layout_close.project_id)
cmd_close:set_parameter("sequence_id", layout_close.sequence_id)
cmd_close:set_parameter("edge_infos", {
    {clip_id = clips_close.v1_left.id, edge_type = "gap_after", track_id = tracks_close.v1.id, trim_type = "ripple"},
    {clip_id = clips_close.v2.id, edge_type = "out", track_id = tracks_close.v2.id, trim_type = "ripple"}
})
cmd_close:set_parameter("lead_edge", {clip_id = clips_close.v2.id, edge_type = "out", track_id = tracks_close.v2.id, trim_type = "ripple"})
cmd_close:set_parameter("delta_frames", -200)

local result_close = command_manager.execute(cmd_close)
assert(result_close.success, result_close.error_message or "Command failed for closing case")

local v1_left_close = Clip.load(clips_close.v1_left.id, db_close)
local v1_right_close = Clip.load(clips_close.v1_right.id, db_close)
local v2_close = Clip.load(clips_close.v2.id, db_close)
local gap_close = v1_right_close.timeline_start.frames - (v1_left_close.timeline_start.frames + v1_left_close.duration.frames)

assert(v2_close.duration.frames == 600,
    string.format("V2 should shrink by 200 (800→600) when dragging left, got %d", v2_close.duration.frames))
assert(gap_close == 800,
    string.format("Gap should close by 200 (expected 800, got %d)", gap_close))
assert(v1_right_close.timeline_start.frames == 2300,
    string.format("Downstream clip should shift left to 2300, got %d", v1_right_close.timeline_start.frames))
print("✅ Multi-track opposing brackets close upstream gaps when dragging left")

layout_close:cleanup()
