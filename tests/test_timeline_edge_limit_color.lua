#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local timeline_renderer = require("ui.timeline.view.timeline_view_renderer")
local timeline_state = require("ui.timeline.timeline_state")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_timeline_edge_limit_color.db"
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
        v1_left = {timeline_start = 0, duration = 800, source_in = 0},
        v1_right = {timeline_start = 4000, duration = 400}
    }
})
local tracks = layout.tracks
local clips = layout.clips

layout:init_timeline_state()

local width, height = 1000, 300

local function build_view()
    return {
        widget = {},
        state = timeline_state,
        filtered_tracks = {{id = tracks.v1.id}, {id = tracks.v2.id}},
        track_layout_cache = {
            by_index = {
                {y = 0, height = 200},
                {y = 210, height = 200}
            },
            by_id = {
                [tracks.v1.id] = {y = 0, height = 200},
                [tracks.v2.id] = {y = 210, height = 200}
            }
        },
        debug_id = "edge-limit-test"
    }
end

local view = build_view()

function view.update_layout_cache() end
function view.get_track_visual_height(track_id)
    return view.track_layout_cache.by_id[track_id].height
end
function view.get_track_id_at_y(y)
    if y < 200 then return tracks.v1.id end
    return tracks.v2.id
end
function view.get_track_y_by_id(track_id)
    return view.track_layout_cache.by_id[track_id].y
end

local original_timeline = timeline
local drawn_rects = {}
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

local function rational(frames)
    return Rational.new(frames, 1000, 1)
end

local limit_color = timeline_state.colors.edge_selected_limit or "#ff0000"
local avail_color = timeline_state.colors.edge_selected_available or "#00ff00"
local gap_start_frames = clips.v1_left.timeline_start + clips.v1_left.duration
local gap_end_frames = clips.v1_right.timeline_start
local temp_gap_id = string.format("temp_gap_%s_%d_%d", tracks.v1.id, gap_start_frames, gap_end_frames)
local gap_edge_key = string.format("%s:%s", temp_gap_id, "gap_after")
local v2_edge_key = string.format("%s:%s", clips.v2.id, "out")

local function count_edge_rects(rects, clip_track_id)
    local counts = {limit = 0, avail = 0}
    local track_entry = view.track_layout_cache.by_id[clip_track_id]
    if not track_entry then
        return counts
    end
    local track_y = track_entry.y
    local height = track_entry.height
    for _, rect in ipairs(rects) do
        if rect.y >= track_y and rect.y <= track_y + height then
            if rect.color == limit_color then
                counts.limit = counts.limit + 1
            elseif rect.color == avail_color then
                counts.avail = counts.avail + 1
            end
        end
    end
    return counts
end

local function render_with_edges(edge_list, delta_frames)
    view.drag_state = {
        type = "edges",
        edges = edge_list,
        lead_edge = edge_list[#edge_list],
        delta_rational = rational(delta_frames)
    }
    timeline_state.set_edge_selection(edge_list)
    drawn_rects = {}
    timeline_renderer.render(view)
    return view.drag_state.preview_clamped_delta, drawn_rects
end

-- Scenario 1: Single edge clamp still flips to limit color
local single_edge = {{clip_id = clips.v1_left.id, edge_type = "out", track_id = tracks.v1.id, trim_type = "ripple"}}
local preview_delta = select(1, render_with_edges(single_edge, 1000))
assert(preview_delta, "preview should record clamped delta")
assert(preview_delta.frames < 1000, "clamped delta should be smaller than requested delta")
local counts_single = count_edge_rects(drawn_rects, tracks.v1.id)
assert(counts_single.limit > 0, "Single edge clamp should render using limit color")

-- Scenario 2: Two-edge drag where only V2 hits the limit
local dual_edges = {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
}
render_with_edges(dual_edges, 600)
local v1_counts = count_edge_rects(drawn_rects, tracks.v1.id)
local v2_counts = count_edge_rects(drawn_rects, tracks.v2.id)
assert(v2_counts.limit > 0, "V2 edge should show limit color when it blocks the drag")
assert(v1_counts.limit == 0, "Gap edge on V1 should stay available color when it isn't the limiter")
assert(view.drag_state.clamped_edges, "Preview should record clamped edge metadata for clamped drags")
assert(view.drag_state.clamped_edges[v2_edge_key],
    "Expected V2 out edge to be marked as clamped when drag exceeds source media")
assert(not view.drag_state.clamped_edges[gap_edge_key],
    "Gap edge should not be marked clamped when only the clip media blocks movement")

timeline = original_timeline
layout:cleanup()
print("✅ Edge preview switches to limit color only for constrained edges")
