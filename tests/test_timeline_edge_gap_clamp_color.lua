#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")
local TimelineActiveRegion = require("core.timeline_active_region")

local TEST_DB = "/tmp/jve/test_timeline_edge_gap_clamp_color.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_right = {
            timeline_start = 1800,
            duration = 1200
        }
    }
})
local clips = layout.clips
local tracks = layout.tracks

layout:init_timeline_state()

local width, height = 1600, 300

local view = {
    widget = {},
    state = timeline_state,
    filtered_tracks = {{id = tracks.v1.id}, {id = tracks.v2.id}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 140},
            [2] = {y = 150, height = 140}
        },
        by_id = {
            [tracks.v1.id] = {y = 0, height = 140},
            [tracks.v2.id] = {y = 150, height = 140}
        }
    },
    debug_id = "edge-gap-clamp"
}

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.height or 0
end
function view.get_track_id_at_y(y)
    return y < 140 and tracks.v1.id or tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    local entry = view.track_layout_cache.by_id[track_id]
    return entry and entry.y or -1
end

local drawn_rects = {}
local original_timeline = timeline
timeline = {
    get_dimensions = function() return width, height end,
    clear_commands = function() drawn_rects = {} end,
    add_rect = function(_, x, y, w, h, color)
        table.insert(drawn_rects, {x = x, y = y, w = w, h = h, color = color})
    end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local function rat(frames)
    return Rational.new(frames, 1000, 1)
end

local gap_edge = {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"}
local clip_edge = {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}

local limit_color = timeline_state.colors.edge_selected_limit or "#ff0000"
local avail_color = timeline_state.colors.edge_selected_available or "#00ff00"
local gap_key = string.format("%s:%s", clips.v1_left.id, "gap_after")
local partner_key = string.format("%s:%s", clips.v1_right.id, "gap_before")
local clip_key = string.format("%s:%s", clips.v2.id, "out")

local function count_track_colors(track_id)
    local counts = {limit = 0, avail = 0}
    local entry = view.track_layout_cache.by_id[track_id]
    for _, rect in ipairs(drawn_rects) do
        if rect.y >= entry.y and rect.y <= entry.y + entry.height then
            if rect.color == limit_color then
                counts.limit = counts.limit + 1
            elseif rect.color == avail_color then
                counts.avail = counts.avail + 1
            end
        end
    end
    return counts
end

local function render_with_edges(edges, lead_edge, delta_frames)
    view.drag_state = {
        type = "edges",
        edges = edges,
        lead_edge = lead_edge,
        delta_rational = rat(delta_frames)
    }
    view.drag_state.timeline_active_region = TimelineActiveRegion.compute_for_edge_drag(timeline_state, edges, {pad_frames = 400})
    view.drag_state.preloaded_clip_snapshot = TimelineActiveRegion.build_snapshot_for_region(timeline_state, view.drag_state.timeline_active_region)
    timeline_state.set_edge_selection(edges)
    drawn_rects = {}
    timeline_renderer.render(view)
    local gap_counts = count_track_colors(tracks.v1.id)
    local clip_counts = count_track_colors(tracks.v2.id)
    return view.drag_state.preview_clamped_delta, view.drag_state.clamped_edges or {}, gap_counts, clip_counts
end

local gap_limited_delta, gap_map, gap_counts2, clip_counts2 = render_with_edges({gap_edge, clip_edge}, gap_edge, 2000)
assert(gap_limited_delta and gap_limited_delta.frames ~= 2000, "Gap-limited scenario should clamp delta")
assert(gap_counts2.limit > 0, "Gap edge should render with limit color when gap space is exhausted")
assert(clip_counts2.limit == 0, "Clip edge should remain available when the gap is the limiter")
assert(gap_map[gap_key], "Dragged gap edge should report the clamp to highlight the user's handle")
assert(not gap_map[partner_key], "Non-selected brackets should remain green in single-track gap clamps")
assert(not gap_map[clip_key], "Clip edge should not be marked clamped when the gap stops movement")

timeline = original_timeline
layout:cleanup()
print("✅ Gap clamp colors remain isolated to the constrained edge")
