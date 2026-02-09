#!/usr/bin/env luajit

require("test_env")

local ripple_layout = require("tests.helpers.ripple_layout")
local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")

local BASE_CLIPS = {
    v1_left = {timeline_start = 0, duration = 1200},
    v1_right = {timeline_start = 2400, duration = 1200},
    v2 = {timeline_start = 1800, duration = 800}
}

local function run_case(delta_frames, expect)
    local layout = ripple_layout.create({
        db_path = string.format("/tmp/jve/test_cross_track_negation_%d.db", delta_frames),
        clips = BASE_CLIPS
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
    cmd:set_parameter("lead_edge", {
        clip_id = clips.v2.id,
        edge_type = "out",
        track_id = tracks.v2.id,
        trim_type = "ripple"
    })
    cmd:set_parameter("delta_frames", delta_frames)

    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "BatchRippleEdit failed for cross-track case")

    local v1_left = Clip.load(clips.v1_left.id, db)
    local v1_right = Clip.load(clips.v1_right.id, db)
    local v2 = Clip.load(clips.v2.id, db)

    local gap_size = v1_right.timeline_start - (v1_left.timeline_start + v1_left.duration)

    assert(gap_size == expect.gap_duration,
        string.format("Gap duration mismatch for delta %d: expected %d, got %d",
            delta_frames, expect.gap_duration, gap_size))
    assert(v1_right.timeline_start == expect.v1_right_start,
        string.format("V1 right start mismatch for delta %d: expected %d, got %d",
            delta_frames, expect.v1_right_start, v1_right.timeline_start))
    assert(v2.duration == expect.v2_duration,
        string.format("V2 duration mismatch for delta %d: expected %d, got %d",
            delta_frames, expect.v2_duration, v2.duration))

    layout:cleanup()
end

-- Drag RIGHT by +200: V2 extends and downstream push opens the gap.
run_case(200, {
    gap_duration = 1400,
    v1_right_start = 2600,
    v2_duration = 1000
})

-- Drag LEFT by -200: V2 shrinks and upstream pull closes the gap.
run_case(-200, {
    gap_duration = 1000,
    v1_right_start = 2200,
    v2_duration = 600
})

print("✅ Cross-track opposing brackets follow the lead edge delta sign (gap opens right, closes left)")
