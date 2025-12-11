#!/usr/bin/env luajit

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local function build_command(layout, clips, tracks, delta, lead_clip)
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
        {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
    })
    local lead = lead_clip == "v2" and clips.v2.id or clips.v1_left.id
    cmd:set_parameter("lead_edge", {
        clip_id = lead,
        edge_type = lead_clip == "v2" and "out" or "gap_after",
        track_id = lead_clip == "v2" and tracks.v2.id or tracks.v1.id,
        trim_type = "ripple"
    })
    cmd:set_parameter("delta_frames", delta)
    return cmd
end

-- Scenario 1: Dragging the V2 ] right should expand the V1 gap, not clamp to the current gap.
do
    local TEST_DB = "/tmp/jve/test_batch_ripple_gap_drag_behavior_expand.db"
    local layout = ripple_layout.create({
        db_path = TEST_DB,
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 1600, duration = 1000},
            v2 = {timeline_start = 1200, duration = 1200}
        }
    })
    local clips = layout.clips
    local tracks = layout.tracks

    -- Dry run: the clamp map should be empty because V2 has plenty of media.
    local dry_cmd = build_command(layout, clips, tracks, 1800, "v2")
    dry_cmd:set_parameter("dry_run", true)
    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok, payload = executor(dry_cmd)
    assert(ok and type(payload) == "table", "Dry run should succeed")
    assert(not payload.clamped_edges or next(payload.clamped_edges) == nil,
        "Dragging V2 ] right should not clamp to the gap")

    -- Execute: V1 right clip should move by the full delta.
    local before = Clip.load(clips.v1_right.id, layout.db).timeline_start.frames
    local cmd = build_command(layout, clips, tracks, 1800, "v2")
    local result = command_manager.execute(cmd)
    assert(result.success, "BatchRippleEdit execute failed for expansion scenario")
    local after = Clip.load(clips.v1_right.id, layout.db).timeline_start.frames
    assert(after - before == 1800,
        string.format("V1 right clip should move by 1800 frames (got %d)", after - before))

    layout:cleanup()
end

-- Scenario 2: Dragging the V1 gap [ left should clamp on V2's media limit.
do
    local TEST_DB = "/tmp/jve/test_batch_ripple_gap_drag_behavior_clamp.db"
    local layout = ripple_layout.create({
        db_path = TEST_DB,
        media = {
            main = {
            duration_frames = 1200,
                fps_numerator = 1000,
                fps_denominator = 1
            }
        },
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 3000, duration = 1000},
            v2 = {timeline_start = 1500, duration = 1200}
        }
    })
    local clips = layout.clips
    local tracks = layout.tracks

    local clamp_delta = -900
    local dry_cmd = build_command(layout, clips, tracks, clamp_delta, "v1")
    dry_cmd:set_parameter("dry_run", true)
    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok, payload = executor(dry_cmd)
    assert(ok and type(payload) == "table", "Dry run should succeed for clamp scenario")
    local clip_key = string.format("%s:%s", clips.v2.id, "out")
    assert(payload.clamped_edges and payload.clamped_edges[clip_key],
        "V2 ] should be reported as the clamped edge when media runs out")

    layout:cleanup()
end

print("✅ BatchRippleEdit handles V2/V1 gap drags correctly")
