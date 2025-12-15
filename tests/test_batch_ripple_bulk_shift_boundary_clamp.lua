#!/usr/bin/env luajit

-- Regression test: when using a preloaded TimelineActiveRegion snapshot, bulk-shift
-- clamping must consider the clip immediately before/after the active region boundary.
-- Otherwise, a negative ripple delta can create VIDEO_OVERLAP on video tracks.

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")
local TimelineActiveRegion = require("core.timeline_active_region")
local Clip = require("models.clip")

do
    local layout = ripple_layout.create({
        db_path = "/tmp/jve/test_batch_ripple_bulk_shift_boundary_clamp.db",
        fps_numerator = 1000,
        tracks = {
            order = {"v1", "v2"},
            v1 = {id = "track_v1", name = "Video 1", track_type = "VIDEO", track_index = 1, enabled = 1},
            v2 = {id = "track_v2", name = "Video 2", track_type = "VIDEO", track_index = 2, enabled = 1},
        },
        clips = {
            order = {"v1_edit", "v2_prev", "v2_next"},
            v1_edit = {track_key = "v1", timeline_start = 0, duration = 1500},
            v2_prev = {track_key = "v2", timeline_start = 0, duration = 1000},
            v2_next = {track_key = "v2", timeline_start = 2000, duration = 1000},
        }
    })

    local state = layout:init_timeline_state()
    local edges = {
        {clip_id = layout.clips.v1_edit.id, edge_type = "out", track_id = layout.tracks.v1.id, trim_type = "ripple"}
    }

    local region = TimelineActiveRegion.compute_for_edge_drag(state, edges, {pad_frames = 50})
    local snapshot = TimelineActiveRegion.build_snapshot_for_region(state, region)

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", edges)
    cmd:set_parameter("delta_frames", -1200)
    cmd:set_parameter("__preloaded_clip_snapshot", snapshot)
    cmd:set_parameter("__timeline_active_region", region)

    local result = command_manager.execute(cmd)
    assert(result.success, "BatchRippleEdit should clamp delta instead of hitting VIDEO_OVERLAP: " .. tostring(result.error_message or "unknown"))

    local after_edit = Clip.load(layout.clips.v1_edit.id, layout.db)
    local after_prev = Clip.load(layout.clips.v2_prev.id, layout.db)
    local after_next = Clip.load(layout.clips.v2_next.id, layout.db)

    assert(after_edit.duration.frames == 500, "V1 edit should clamp to delta=-1000 (duration 500)")
    assert(after_prev.timeline_start.frames == 0, "V2 prev should not shift (before ripple point)")
    assert(after_next.timeline_start.frames == 1000, "V2 next should clamp to start=1000 (no overlap)")

    layout:cleanup()
end

print("✅ Bulk-shift boundary clamping works with TimelineActiveRegion snapshots")
