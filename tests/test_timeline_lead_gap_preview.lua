#!/usr/bin/env luajit

require("test_env")

local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local TimelineActiveRegion = require("core.timeline_active_region")

local TEST_DB = "/tmp/jve/test_timeline_lead_gap_preview.db"
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

layout:init_timeline_state()

local width, height = 1600, 320
local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}, {id = tracks.v2.id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 150},
            [2] = {y = 160, height = 150}
        },
        by_id = {
            [tracks.v1.id] = {y = 0, height = 150},
            [tracks.v2.id] = {y = 160, height = 150}
        }
    },
    debug_id = "lead-gap-preview"
}

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.height or 0
end
function view.get_track_id_at_y(y)
    return y < 150 and tracks.v1.id or tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local gap_edge = {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"}
local clip_edge = {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}

view.drag_state = {
    type = "edges",
    edges = {gap_edge, clip_edge},
    lead_edge = clip_edge,
    delta_frames = 1800
}
view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(timeline_state, view.drag_state.edges, {pad_frames = 400})
view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)

timeline_state.set_edge_selection({gap_edge, clip_edge})

local original_timeline = timeline
local drawn_rects = {}
timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() drawn_rects = {} end,
    add_rect = function() end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local ok, err = pcall(function()
    timeline_renderer.render(view)
end)

timeline = original_timeline

layout:cleanup()

assert(ok, "timeline renderer should not error: " .. tostring(err))
local preview_delta = view.drag_state.preview_clamped_delta_frames
assert(preview_delta, "Preview should record clamped delta")
assert(preview_delta == 1800,
    string.format("Lead gap drag should not clamp to gap size (expected 1800, got %d)", preview_delta))
local clamped_edges = view.drag_state.clamped_edges or {}
local gap_key = string.format("%s:%s", clips.v1_left.id, "gap_after")
assert(not clamped_edges[gap_key], "Gap edge should not be marked clamped when V2 has available media")

print("✅ Lead gap drags reflect clip limits, not gap length")
