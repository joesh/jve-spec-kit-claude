#!/usr/bin/env luajit

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_batch_ripple_implied_gap_clamp.db",
    clips = {
        order = {"v1_left", "v2_blocker", "v2_shift", "v1_right"},
        v1_right = {
            timeline_start = 4200,
            duration = 1200
        },
        v2_blocker = {
            id = "clip_v2_blocker",
            track_key = "v2",
            timeline_start = 3600,
            duration = 400
        },
        v2_shift = {
            id = "clip_v2_shift",
            track_key = "v2",
            timeline_start = 4400,
            duration = 800
        }
    }
})

local tracks = layout.tracks
local clips = layout.clips

local executor = command_manager.get_executor("BatchRippleEdit")
assert(executor, "BatchRippleEdit executor missing")

local function track_id_for_clip(entry)
    local track = entry and tracks[entry.track_key]
    return track and track.id
end

local function run_implied_clamp(delta_frames)
    local gap_edge = {
        clip_id = clips.v1_right.id,
        edge_type = "gap_before",
        track_id = track_id_for_clip(clips.v1_right),
        trim_type = "ripple"
    }

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {gap_edge})
    cmd:set_parameter("lead_edge", gap_edge)
    cmd:set_parameter("delta_frames", delta_frames)
    cmd:set_parameter("dry_run", true)

    local ok, payload = executor(cmd)
    assert(ok and type(payload) == "table", "Dry run should succeed for implied clamp scenario")

    local implied_key = string.format("%s:%s", clips.v2_shift.id, "gap_before")
    assert(payload.clamped_edges and payload.clamped_edges[implied_key],
        "Implied downstream gap should be identified as the blocking edge")

    local dragged_key = string.format("%s:%s", gap_edge.clip_id, gap_edge.edge_type)
    assert(not payload.clamped_edges[dragged_key],
        "Dragged bracket should remain available when another track blocks the ripple")

    local upstream_key = string.format("%s:%s", clips.v2_blocker.id, "gap_after")
    assert(not payload.clamped_edges[upstream_key],
        "Only the implied limiter should be flagged; upstream brackets should remain available")
end

run_implied_clamp(-1500)

layout:cleanup()
print("✅ Implied downstream clamps attribute limiters to the correct gap edges")
