#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test to verify cross-track opposing bracket negation behavior
-- This tests whether the share_edit_point logic is working as intended

local TEST_DB = "/tmp/jve/test_cross_track_negation.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {timeline_start = 2500},  -- Gap from 1500-2500
        v2 = {timeline_start = 1800, duration = 800}  -- V2: 1800-2600
    }
})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

print("BEFORE:")
print(string.format("  V1: 0-1500, gap 1500-2500, right 2500-3700"))
print(string.format("  V2: 1800-2600"))
print(string.format("  Edges are on DIFFERENT tracks and DIFFERENT boundaries"))
print(string.format("  V2 out ] at t=2600 (track v2)"))
print(string.format("  V1 gap [ at t=1500 (track v1)"))

-- Drag right +200 with V2 as lead
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
print(string.format("  V1 gap: %d-%d (%d frames)",
    v1_left.timeline_start.frames + v1_left.duration.frames,
    v1_right.timeline_start.frames,
    gap_size))
print(string.format("  V2:     %d-%d (%d frames)",
    v2.timeline_start.frames,
    v2.timeline_start.frames + v2.duration.frames,
    v2.duration.frames))

-- With cross-track negation: gap grows to 1200
-- Without cross-track negation: gap shrinks to 800
assert(gap_size == 800,
    string.format("Cross-track selections should share the lead delta; expected gap to shrink to 800, got %d", gap_size))
print("\n✅ Cross-track handles follow the lead edge delta (gap shrank to 800)")

layout:cleanup()
