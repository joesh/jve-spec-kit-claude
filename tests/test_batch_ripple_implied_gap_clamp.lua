#!/usr/bin/env luajit

-- Updated for gap-as-clip: gap_before on v1_right → gap clip "out" edge;
-- implied gap_before on v2_shift → implied gap clip "out" edge

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

local function run_implied_clamp(delta_frames)
    -- v1_left ends at 1500, v1_right starts at 4200 → gap is 1500..4200
    -- gap_id = gap_track_v1_1500
    local gap_id = layout:gap_id("v1", 1500)

    local gap_edge = {
        clip_id = gap_id,
        edge_type = "out",
        track_id = tracks.v1.id,
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

    -- v2_blocker ends at 4000, v2_shift starts at 4400 → implied gap is 4000..4400
    -- implied gap_id = gap_track_v2_4000
    local implied_gap_id = layout:gap_id("v2", 4000)
    local implied_key = string.format("%s:%s", implied_gap_id, "out")
    assert(payload.clamped_edges and payload.clamped_edges[implied_key],
        "Implied downstream gap should be identified as the blocking edge")

    local dragged_key = string.format("%s:%s", gap_edge.clip_id, gap_edge.edge_type)
    assert(not payload.clamped_edges[dragged_key],
        "Dragged bracket should remain available when another track blocks the ripple")

    -- v2_blocker ends at 4000, gap_after on v2_blocker → gap clip "in" edge
    local upstream_gap_id = layout:gap_id("v2", 4000)
    local upstream_key = string.format("%s:%s", upstream_gap_id, "in")
    assert(not payload.clamped_edges[upstream_key],
        "Only the implied limiter should be flagged; upstream brackets should remain available")
end

run_implied_clamp(-1500)

layout:cleanup()
print("✅ Implied downstream clamps attribute limiters to the correct gap edges")
