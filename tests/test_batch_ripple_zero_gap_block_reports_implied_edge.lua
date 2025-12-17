#!/usr/bin/env luajit

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")

-- Regression: When a shifting track has *no* gap at the boundary (zero-length gap),
-- BatchRippleEdit should clamp to 0 and report the implied gap edge as the limiter.
-- This ensures the renderer can highlight the correct (implied) edge even when
-- nothing shifts.
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_zero_gap_block_reports_implied_edge.db",
        clips = {
            order = {"v1_left", "v1_right", "v2_prefix", "v2_shift"},
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}, -- V1 gap = 1000
            v2_prefix = {id = "clip_v2_prefix", track_key = "v2", timeline_start = 0, duration = 1400},
            v2_shift = {id = "clip_v2_shift", track_key = "v2", timeline_start = 1400, duration = 500}, -- zero gap
        }
    })

    local executor = command_manager.get_executor("BatchRippleEdit")
    assert(executor, "BatchRippleEdit executor missing")

    local lead_edge = {
        clip_id = layout.clips.v1_left.id,
        edge_type = "gap_after", -- normalized "in"
        track_id = layout.tracks.v1.id,
        trim_type = "ripple",
    }

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {lead_edge})
    cmd:set_parameter("lead_edge", lead_edge)
    cmd:set_parameter("delta_frames", 500) -- closing the V1 gap shifts downstream left
    cmd:set_parameter("dry_run", true)

    local ok, payload = executor(cmd)
    assert(ok and type(payload) == "table", "Dry run should succeed")
    assert(payload.clamped_delta_ms == 0,
        string.format("Expected clamp to 0 due to zero-length gap; got clamped_delta_ms=%s", tostring(payload.clamped_delta_ms)))

    local implied_key = string.format("%s:%s", layout.clips.v2_shift.id, "gap_before")
    assert(payload.clamped_edges and payload.clamped_edges[implied_key],
        "Expected implied zero-gap edge to be reported as clamped: " .. implied_key)

    assert(type(payload.edge_preview) == "table" and type(payload.edge_preview.edges) == "table",
        "Expected dry-run payload to include edge_preview.edges")
    local found = false
    for _, entry in ipairs(payload.edge_preview.edges) do
        if entry and entry.edge_key == implied_key then
            assert(entry.is_implied == true, "Expected limiter edge_preview entry to be implied")
            assert(entry.is_limiter == true, "Expected limiter edge_preview entry to be marked is_limiter")
            found = true
            break
        end
    end
    assert(found, "Expected edge_preview to include limiter entry for " .. implied_key)

    layout:cleanup()
end

print("✅ BatchRippleEdit reports implied clamp edge for zero-length gaps")
