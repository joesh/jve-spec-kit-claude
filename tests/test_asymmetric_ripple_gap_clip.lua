#!/usr/bin/env luajit

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Test asymmetric ripple with gap_after [  and clip out ]
-- This tests the "opposing brackets" logic (Rule 11)
local CANONICAL_LAYOUT = {
    v1_left = {timeline_start = 0, duration = 1500},
    v1_right = {timeline_start = 3500, duration = 1200},
    v2 = {timeline_start = 2000, duration = 1000}
}

local function run_asymmetric_case(delta_frames, expect)
    local db_path = string.format("/tmp/jve/test_asymmetric_ripple_gap_clip_%d.db", delta_frames)
    local layout = ripple_layout.create({
        db_path = db_path,
        clips = CANONICAL_LAYOUT
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
    cmd:set_parameter("delta_frames", delta_frames)

    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "BatchRippleEdit failed for asymmetric case")

    local v1_left = Clip.load(clips.v1_left.id, db)
    local v1_right = Clip.load(clips.v1_right.id, db)
    local v2 = Clip.load(clips.v2.id, db)

    local gap_size = v1_right.timeline_start - (v1_left.timeline_start + v1_left.duration)

    assert(v2.duration == expect.v2_duration,
        string.format("V2 duration mismatch for delta %d: expected %d, got %d",
            delta_frames, expect.v2_duration, v2.duration))
    assert(v2.timeline_start == expect.v2_start,
        string.format("V2 start mismatch for delta %d: expected %d, got %d",
            delta_frames, expect.v2_start, v2.timeline_start))
    assert(gap_size == expect.gap_duration,
        string.format("Gap duration mismatch for delta %d: expected %d, got %d",
            delta_frames, expect.gap_duration, gap_size))
    assert(v1_right.timeline_start == expect.v1_right_start,
        string.format("V1 right start mismatch for delta %d: expected %d, got %d",
            delta_frames, expect.v1_right_start, v1_right.timeline_start))

    layout:cleanup()
end

-- Drag RIGHT by +200: V2 extends and gap opens by 200 (downstream push).
run_asymmetric_case(200, {
    v2_duration = 1200,
    v2_start = 2000,
    gap_duration = 2200,
    v1_right_start = 3700
})

-- Drag LEFT by -200: V2 should shrink and the V1 gap should also shrink by 200.
run_asymmetric_case(-200, {
    v2_duration = 800,
    v2_start = 2000,
    gap_duration = 1800,
    v1_right_start = 3300
})

print("✅ Asymmetric ripple cases assert clip/gap symmetry for ±delta")
