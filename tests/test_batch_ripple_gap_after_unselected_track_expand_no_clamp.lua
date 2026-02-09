#!/usr/bin/env luajit

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")

local function find_shifted_clip(payload, clip_id)
    if not payload or not payload.shifted_clips then
        return nil
    end
    for _, info in ipairs(payload.shifted_clips) do
        if info.clip_id == clip_id then
            return info
        end
    end
    return nil
end

-- Regression: Opening a lead gap_after ([) should not be clamped by the
-- gap-before width on unselected tracks (opening creates space; no collision risk).
do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_gap_after_unselected_track_expand_no_clamp.db",
        clips = {
            order = {"v1_left", "v1_right", "v2_prefix", "v2_shift"},
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 1000}, -- V1 gap = 1000
            v2_prefix = {id = "clip_v2_prefix", track_key = "v2", timeline_start = 0, duration = 1400},
            v2_shift = {id = "clip_v2_shift", track_key = "v2", timeline_start = 1500, duration = 500}, -- 100 frame gap on V2
        }
    })

    local executor = command_manager.get_executor("BatchRippleEdit")
    assert(executor, "BatchRippleEdit executor missing")

    local lead_edge = {
        clip_id = layout.clips.v1_left.id,
        edge_type = "gap_after",
        track_id = layout.tracks.v1.id,
        trim_type = "ripple",
    }

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {lead_edge})
    cmd:set_parameter("lead_edge", lead_edge)
    cmd:set_parameter("delta_frames", -500) -- Open the gap (drag left on [)
    cmd:set_parameter("dry_run", true)

    local ok, payload = executor(cmd)
    assert(ok and type(payload) == "table", "Dry run should succeed")

    assert(payload.clamped_delta_ms == -500,
        string.format("Expected no clamp when opening lead gap_after; got clamped_delta_ms=%s", tostring(payload.clamped_delta_ms)))
    assert(not payload.clamped_edges or next(payload.clamped_edges) == nil,
        "Expected no clamped edges when opening lead gap_after")

    local v1_shifted = find_shifted_clip(payload, layout.clips.v1_right.id)
    assert(v1_shifted and v1_shifted.new_start_value and v1_shifted.new_start_value == 2500,
        string.format("Expected V1 right clip to shift right by 500 (to 2500); got %s",
            tostring(v1_shifted and v1_shifted.new_start_value and v1_shifted.new_start_value)))

    local v2_shifted = find_shifted_clip(payload, layout.clips.v2_shift.id)
    assert(v2_shifted and v2_shifted.new_start_value and v2_shifted.new_start_value == 2000,
        string.format("Expected V2 shift clip to shift right by 500 (to 2000); got %s",
            tostring(v2_shifted and v2_shifted.new_start_value and v2_shifted.new_start_value)))

    layout:cleanup()
end

print("✅ BatchRippleEdit does not clamp opening lead gap_after due to unselected track gaps")

