#!/usr/bin/env luajit

-- Updated for gap-as-clip: gap_after on v1_left → gap clip "in" edge

require("test_env")

local ripple_layout = require("tests.helpers.ripple_layout")
local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")

local db_path = "/tmp/jve/test_asymmetric_ripple_gap_close.db"
local layout = ripple_layout.create({
    db_path = db_path,
    clips = {
        v1_left = {sequence_start = 0, duration = 1500},
        v1_right = {sequence_start = 3500, duration = 1200},
        v2 = {sequence_start = 2000, duration = 1000}
    }
})

local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

local function current_gap_frames()
    local v1_left = Clip.load(clips.v1_left.id, db)
    local v1_right = Clip.load(clips.v1_right.id, db)
    return v1_right.sequence_start - (v1_left.sequence_start + v1_left.duration),
        v1_right.sequence_start
end

local initial_gap, initial_right_start = current_gap_frames()
assert(initial_gap == 2000,
    string.format("test precondition failed: expected initial gap 2000, got %d", initial_gap))
assert(initial_right_start == 3500,
    string.format("test precondition failed: expected V1 right start 3500, got %d", initial_right_start))

-- v1_left ends at 1500, gap is 1500..3500 → gap_id = gap_track_v1_1500
local gap_id = layout:gap_id("v1", 1500)

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = gap_id, edge_type = "in", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", -200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed for asymmetric gap close")

local v2_after = Clip.load(clips.v2.id, db)
local gap_after, right_start_after = current_gap_frames()

assert(v2_after.duration == 800,
    string.format("V2 duration mismatch: expected 800 got %d", v2_after.duration))
assert(gap_after == initial_gap - 200,
    string.format("Gap should shrink by 200 frames: expected %d got %d", initial_gap - 200, gap_after))
assert(right_start_after == initial_right_start - 200,
    string.format("V1 right should shift left by 200 frames: expected %d got %d",
        initial_right_start - 200, right_start_after))

layout:cleanup()

print("✅ Asymmetric ripple closes V1 gap when dragging V2 ] left")
