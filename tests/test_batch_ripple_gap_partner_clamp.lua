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

local function track_id_for_clip(clip_entry)
    local track = layout.tracks[clip_entry.track_key]
    return track and track.id
end

local function assert_clamp(edge_clip_entry, edge_type, partner_clip_entry, partner_edge_type, delta_frames, scenario_label)
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = edge_clip_entry.id, edge_type = edge_type, track_id = track_id_for_clip(edge_clip_entry), trim_type = "ripple"}
    })
    cmd:set_parameter("lead_edge", {clip_id = edge_clip_entry.id, edge_type = edge_type, track_id = track_id_for_clip(edge_clip_entry), trim_type = "ripple"})
    cmd:set_parameter("delta_frames", delta_frames)
    cmd:set_parameter("dry_run", true)

    local ok, payload = executor(cmd)
    assert(ok and type(payload) == "table", "Dry run should return payload table (" .. scenario_label .. ")")
    assert(payload.clamped_edges and next(payload.clamped_edges), "Clamped edges should identify the limiter (" .. scenario_label .. ")")

    local dragged_key = string.format("%s:%s", edge_clip_entry.id, edge_type)
    local partner_key = string.format("%s:%s", partner_clip_entry.id, partner_edge_type)

    assert(payload.clamped_edges[dragged_key],
        "Dragged gap edge must report the clamp when its movement is limited (" .. scenario_label .. ")")
    assert(not payload.clamped_edges[partner_key],
        "Only the user-dragged edge should be flagged as limited (" .. scenario_label .. ")")
end

assert_clamp(
    layout.clips.v1_left,
    "gap_after",
    layout.clips.v1_right,
    "gap_before",
    5000,
    "positive gap expansion"
)

assert_clamp(
    layout.clips.v1_right,
    "gap_before",
    layout.clips.v1_left,
    "gap_after",
    -5000,
    "negative gap collapse"
)

local function assert_dragged_clamp_with_selected_partner(delta_frames, scenario_label)
    local left_gap = {
        clip_id = layout.clips.v1_left.id,
        edge_type = "gap_after",
        track_id = track_id_for_clip(layout.clips.v1_left),
        trim_type = "ripple"
    }
    local right_gap = {
        clip_id = layout.clips.v1_right.id,
        edge_type = "gap_before",
        track_id = track_id_for_clip(layout.clips.v1_right),
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
