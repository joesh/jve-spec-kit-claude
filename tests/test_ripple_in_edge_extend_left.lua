#!/usr/bin/env luajit

require("test_env")

local ripple_layout = require("tests.helpers.ripple_layout")
local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")

local TEST_DB = "/tmp/jve/test_ripple_in_edge_extend_left.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {
            source_in = 400
        }
    }
})
local clips = layout.clips
local tracks = layout.tracks

local delta = -400 -- Drag the [ handle left by 400 frames

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "ripple"}
})
cmd:set_parameter("delta_frames", delta)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "In-edge ripple should succeed")

local updated = Clip.load(clips.v1_right.id, layout.db)
local expected_start = clips.v1_right.timeline_start
local expected_duration = clips.v1_right.duration - delta -- subtracting a negative grows length

assert(updated.timeline_start == expected_start,
    string.format("Ripple should keep clip start anchored; expected %d, got %d",
        expected_start, updated.timeline_start))
assert(updated.duration == expected_duration,
    string.format("Dragging [ left should extend clip duration by -delta; expected %d, got %d",
        expected_duration, updated.duration))

layout:cleanup()
print("✅ In-edge ripple extends the clip when dragging [ left")
