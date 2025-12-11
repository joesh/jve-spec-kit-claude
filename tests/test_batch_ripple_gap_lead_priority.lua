#!/usr/bin/env luajit

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")

local function build_layout()
    return ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_gap_lead_priority.db",
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000},
            v2 = {timeline_start = 1200, duration = 1200, source_in = 600}
        }
    })
end

local function default_edge_infos(layout)
    local clips = layout.clips
    local tracks = layout.tracks
    return {
        {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
        {clip_id = clips.v2.id, edge_type = "in", track_id = tracks.v2.id, trim_type = "ripple"}
    }
end

local function build_command(layout, delta, overrides)
    overrides = overrides or {}
    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", overrides.edge_infos or default_edge_infos(layout))
    cmd:set_parameter("lead_edge", overrides.lead_edge or {
        clip_id = layout.clips.v1_left.id,
        edge_type = "gap_after",
        track_id = layout.tracks.v1.id,
        trim_type = "ripple"
    })
    cmd:set_parameter("delta_frames", delta)
    cmd:set_parameter("dry_run", true)
    return cmd
end

local function execute(layout, delta, overrides)
    local cmd = build_command(layout, delta, overrides)
    local executor = command_manager.get_executor("BatchRippleEdit")
    assert(executor, "BatchRippleEdit executor missing")
    local ok, payload = executor(cmd)
    assert(ok and type(payload) == "table", "Dry run should succeed")
    return payload
end

local function find_affected_clip(payload, clip_id)
    if not payload.affected_clips then
        return nil
    end
    for _, info in ipairs(payload.affected_clips) do
        if info.clip_id == clip_id then
            return info
        end
    end
    return nil
end

-- Case within limits: lead gap honors requested delta both directions.
do
    local layout = build_layout()
    local payload = execute(layout, 600)
    assert(payload.clamped_delta_ms == 600, "positive drag should not be clamped when slack exists")
    assert(not payload.clamped_edges or next(payload.clamped_edges) == nil,
        "no edges should be clamped on positive drag with slack")
    layout:cleanup()
end

do
    local layout = build_layout()
    local payload = execute(layout, -400)
    assert(payload.clamped_delta_ms == -400, "negative drag within clip handle should succeed")
    assert(not payload.clamped_edges or next(payload.clamped_edges) == nil,
        "no edges should be clamped when handle slack remains")
    layout:cleanup()
end

-- Clamp occurs when lead gap overdraws the clip handle.
do
    local layout = build_layout()
    local payload = execute(layout, -800)
    assert(payload.clamped_delta_ms == -600,
        string.format("lead gap should clamp at clip handle (expected -600, got %s)", tostring(payload.clamped_delta_ms)))
    local clamp_key = string.format("%s:%s", layout.clips.v2.id, "in")
    assert(payload.clamped_edges and payload.clamped_edges[clamp_key],
        "lead gap overdraw should report the clip edge that limited the delta")
    layout:cleanup()
end

-- Opposing brackets should still negate the delta even when they live on different tracks.
do
    local layout = build_layout()
    local clips = layout.clips
    local tracks = layout.tracks
    local payload = execute(layout, -200, {
        edge_infos = {
            {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
            {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
        }
    })
    local affected = find_affected_clip(payload, clips.v2.id)
    assert(affected, "v2 clip should be affected when its out edge is selected")
    local new_duration = affected.new_duration and affected.new_duration.frames
    assert(new_duration, "affected clip should report new duration")
    assert(new_duration > layout.clips.v2.duration,
        string.format("v2 duration should grow when lead gap delta is negative and opposing bracket negates it (got %s)", tostring(new_duration)))
    layout:cleanup()
end

print("✅ Lead gap selections obey clip limits and opposing brackets negate delta per Rule 11")
