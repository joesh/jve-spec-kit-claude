#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_gap_roll_execution.db"
local layout = ripple_layout.create({db_path = TEST_DB})
local clips = layout.clips
local tracks = layout.tracks

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "roll"},
    {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"})
cmd:set_parameter("delta_frames", 200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "Gap roll execution failed")

local left = Clip.load(clips.v1_left.id, layout.db)
local right = Clip.load(clips.v1_right.id, layout.db)

assert(left.timeline_start.frames == 0, "Left clip timeline_start should remain anchored")
assert(left.duration.frames == 1500, "Left clip duration should not change during roll")

assert(right.timeline_start.frames == 3700,
    string.format("Right clip start should move right by 200, got %d", right.timeline_start.frames))
assert(right.duration.frames == 1000,
    string.format("Right clip duration should shrink by 200, got %d", right.duration.frames))

layout:cleanup()
print("✅ Gap roll adjusts downstream clip without shifting the timeline")
