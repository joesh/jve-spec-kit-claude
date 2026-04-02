#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_batch_ripple_lead_edge.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {timeline_start = 2600},
        v2 = {timeline_start = 1800, duration = 800}
    }
})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

-- Gap on V1 between v1_left (end=1500) and v1_right (start=2600): gap starts at 1500
local gap_id = layout:gap_id("v1", 1500)

-- Select V1 gap in-edge and V2 out edge; drag V2 ] left by 200 frames.
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = gap_id, edge_type = "in", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", -200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit mixed gap selection failed")

local target_clip = Clip.load(clips.v2.id, db)
assert(target_clip.duration == 600, string.format("Expected V2 clip to shrink by 200 frames, got %s", tostring(target_clip.duration)))

layout:cleanup()
print("✅ BatchRippleEdit shrinks the dragged clip even when a gap edge is also selected")
