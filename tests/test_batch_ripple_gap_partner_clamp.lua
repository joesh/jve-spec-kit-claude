#!/usr/bin/env luajit

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")

local layout = ripple_layout.create({
    db_path = "/tmp/jve/test_batch_ripple_gap_partner_clamp.db",
    clips = {
        v1_left = {timeline_start = 0, duration = 1000},
        v1_right = {timeline_start = 4000, duration = 600}
    }
})

local executor = command_manager.get_executor("BatchRippleEdit")
assert(executor, "BatchRippleEdit executor missing")

-- v1_left ends at 1000, v1_right starts at 4000 → gap is 1000..4000
-- gap_id = gap_track_v1_1000
local gap_id = layout:gap_id("v1", 1000)

local function assert_clamp(edge_type, partner_edge_type, delta_frames, scenario_label)
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = gap_id, edge_type = edge_type, track_id = layout.tracks.v1.id, trim_type = "ripple"}
    })
    cmd:set_parameter("lead_edge", {clip_id = gap_id, edge_type = edge_type, track_id = layout.tracks.v1.id, trim_type = "ripple"})
    cmd:set_parameter("delta_frames", delta_frames)
    cmd:set_parameter("dry_run", true)

    local ok, payload = executor(cmd)
    assert(ok and type(payload) == "table", "Dry run should return payload table (" .. scenario_label .. ")")
    assert(payload.clamped_edges and next(payload.clamped_edges), "Clamped edges should identify the limiter (" .. scenario_label .. ")")

    local dragged_key = string.format("%s:%s", gap_id, edge_type)
    local partner_key = string.format("%s:%s", gap_id, partner_edge_type)

    assert(payload.clamped_edges[dragged_key],
        "Dragged gap edge must report the clamp when its movement is limited (" .. scenario_label .. ")")
    assert(not payload.clamped_edges[partner_key],
        "Only the user-dragged edge should be flagged as limited (" .. scenario_label .. ")")
end

assert_clamp(
    "in",
    "out",
    5000,
    "positive gap expansion"
)

assert_clamp(
    "out",
    "in",
    -5000,
    "negative gap collapse"
)

local function assert_dragged_clamp_with_selected_partner(delta_frames, scenario_label)
    local left_gap = {
        clip_id = gap_id,
        edge_type = "in",
        track_id = layout.tracks.v1.id,
        trim_type = "ripple"
    }
    local right_gap = {
        clip_id = gap_id,
        edge_type = "out",
        track_id = layout.tracks.v1.id,
        trim_type = "ripple"
    }
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {left_gap, right_gap})
    cmd:set_parameter("lead_edge", left_gap)
    cmd:set_parameter("delta_frames", delta_frames)
    cmd:set_parameter("dry_run", true)

    local ok, payload = executor(cmd)
    assert(ok and type(payload) == "table", "Dry run should succeed for selected-partner clamp (" .. scenario_label .. ")")
    local dragged_key = string.format("%s:%s", left_gap.clip_id, left_gap.edge_type)
    assert(payload.clamped_edges and payload.clamped_edges[dragged_key],
        "Lead gap edge should be marked as the limiter when its partner edge is also selected (" .. scenario_label .. ")")
end

assert_dragged_clamp_with_selected_partner(5000, "selected partner roll clamp")

layout:cleanup()
print("✅ Gap partner clamp highlights the stationary edge in both directions")
