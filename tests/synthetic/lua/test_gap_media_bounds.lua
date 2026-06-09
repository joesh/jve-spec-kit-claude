#!/usr/bin/env luajit

-- Updated for gap-as-clip: gap_after on v1_left → gap clip "in" edge

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("synthetic.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_gap_media_bounds.db"
local layout = ripple_layout.create({
    db_path = TEST_DB
})
local db = layout.db
local clips = layout.clips

-- v1_left ends at 1500, v1_right starts at 3500 → gap is 1500..3500
local gap_id = layout:gap_id("v1", 1500)

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = gap_id, edge_type = "in", track_id = layout.tracks.v1.id, trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", 2000)

local result = command_manager.execute(cmd)
assert(result.success, "Gap edge ripple should succeed without media-bound clamp")

local left = Clip.load(clips.v1_left.id, db)
local right = Clip.load(clips.v1_right.id, db)

assert(left.sequence_start == 0, "Upstream clip should stay anchored")
assert(left.duration == 1500, "Upstream clip duration should stay constant")

assert(right.sequence_start == 1500,
    string.format("Downstream clip should shift upstream to close the gap; expected 1500, got %d",
        right.sequence_start))
assert(right.duration == 1200, "Downstream clip duration should be preserved")
assert(right.source_in == 0 and right.source_out == 1200,
    "Downstream clip media bounds should remain unchanged")

layout:cleanup()
print("✅ Gap edges ignore media bounds while keeping downstream clip media intact")
