#!/usr/bin/env luajit

require("test_env")

local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local TimelineActiveRegion = require("core.timeline_active_region")

local TEST_DB = "/tmp/jve/test_timeline_edge_min_duration_clamp.db"
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
        order = {"v1_left"},
        v1_left = {timeline_start = 0, duration = 5, source_in = 0},
    }
})

layout:init_timeline_state()

local tracks = layout.tracks
local clips = layout.clips

local width, height = 1000, 200

local function build_view()
    return {
        widget = {},
        state = timeline_state,
        filtered_tracks = {{id = tracks.v1.id}},
        track_layout_cache = {
            by_index = {
                {y = 0, height = 200},
            },
            by_id = {
                [tracks.v1.id] = {y = 0, height = 200},
            }
        },
        debug_id = "edge-min-duration-test"
    }
end

local view = build_view()

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    return view.track_layout_cache.by_id[track_id].height
end
function view.get_track_id_at_y()
    return tracks.v1.id
end
function view.get_track_y_by_id(track_id)
    return view.track_layout_cache.by_id[track_id].y
end

local original_timeline = timeline
timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() end,
    add_rect = function() end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local edge = {clip_id = clips.v1_left.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "ripple"}
view.drag_state = {
    type = "edges",
    edges = {edge},
    lead_edge = edge,
    delta_frames = 1000,
}
view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(timeline_state, view.drag_state.edges, {pad_frames = 400})
view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)
timeline_state.set_edge_selection({edge})

timeline_renderer.render(view)

assert(view.drag_state.preview_clamped_delta_frames, "expected preview to compute a clamped delta for over-shrinking clips")
assert(view.drag_state.preview_clamped_delta_frames == 5,
    "expected in-edge shrink to clamp at full duration (5 frames = deletes clip)")
assert(view.drag_state.preview_data, "expected preview_data to exist (dry run should succeed)")

timeline = original_timeline
layout:cleanup()
print("✅ Edge preview clamps to min clip duration")
