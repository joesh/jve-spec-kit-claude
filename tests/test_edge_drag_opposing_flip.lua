#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;./tests/?.lua;" .. package.path

require("test_env")

local ripple_layout = require("tests.helpers.ripple_layout")
local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_edge_flip.db",
    clips = {
        v1_left = {timeline_start = 0, duration = 1200},
        v1_right = {timeline_start = 2400, duration = 1200},
        v2 = {timeline_start = 1800, duration = 800}
    }
})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", -200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed")

local v1_left = Clip.load(clips.v1_left.id, db)
local v1_right = Clip.load(clips.v1_right.id, db)
local v2 = Clip.load(clips.v2.id, db)

local gap_size = v1_right.timeline_start - (v1_left.timeline_start + v1_left.duration)
assert(gap_size == 1000, string.format("Gap should close to 1000 frames, got %d", gap_size))
assert(v1_right.timeline_start == 2200,
    string.format("V1 right clip should shift left to 2200, got %d", v1_right.timeline_start))
assert(v2.duration == 600,
    string.format("V2 duration should trim to 600, got %d", v2.duration))
print("✅ Edge drag opposing handles close the intervening gap")

layout:cleanup()
