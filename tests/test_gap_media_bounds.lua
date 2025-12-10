#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_gap_media_bounds.db"
local layout = ripple_layout.create({
    db_path = TEST_DB
})
local db = layout.db
local clips = layout.clips

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = layout.tracks.v1.id, trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", 2000)

local result = command_manager.execute(cmd)
assert(result.success, "Gap edge ripple should succeed without media-bound clamp")

local left = Clip.load(clips.v1_left.id, db)
local right = Clip.load(clips.v1_right.id, db)

assert(left.timeline_start.frames == 0, "Upstream clip should stay anchored")
assert(left.duration.frames == 1500, "Upstream clip duration should stay constant")

assert(right.timeline_start.frames == 1500,
    string.format("Downstream clip should shift upstream to close the gap; expected 1500, got %d",
        right.timeline_start.frames))
assert(right.duration.frames == 1200, "Downstream clip duration should be preserved")
assert(right.source_in.frames == 0 and right.source_out.frames == 1200,
    "Downstream clip media bounds should remain unchanged")

layout:cleanup()
print("✅ Gap edges ignore media bounds while keeping downstream clip media intact")
