#!/usr/bin/env luajit

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_ripple_media_boundary.db"
local extra_media_frames = 1800

local layout = ripple_layout.create({
    db_path = TEST_DB,
    media = {
        main = {
            duration_frames = extra_media_frames,
            fps_numerator = 1000,
            fps_denominator = 1
        }
    },
    clips = {
        v1_left = {timeline_start = 0, duration = 1000},
        v1_right = {timeline_start = 2500, duration = 800}
    }
})

local clips = layout.clips
local tracks = layout.tracks
local db = layout.db

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "out", track_id = tracks.v1.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v1_left.id, edge_type = "out", track_id = tracks.v1.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", 1400)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed for media clamp")

local left_clip = Clip.load(clips.v1_left.id, db)
local right_clip = Clip.load(clips.v1_right.id, db)

assert(left_clip.duration == extra_media_frames,
    string.format("Left clip should extend only to available media (%d), got %d", extra_media_frames, left_clip.duration))
assert(left_clip.source_out == extra_media_frames,
    string.format("Left clip source_out should equal media duration (%d), got %d", extra_media_frames, left_clip.source_out))

local expected_shift = extra_media_frames - clips.v1_left.duration
assert(right_clip.timeline_start == clips.v1_right.timeline_start + expected_shift,
    string.format("Downstream clip should shift by %d frames, got %d",
        expected_shift, right_clip.timeline_start - clips.v1_right.timeline_start))

layout:cleanup()
print("✅ Ripple clamps at media boundary and shifts downstream clips accordingly")
