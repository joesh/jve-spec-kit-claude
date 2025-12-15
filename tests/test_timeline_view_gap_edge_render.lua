#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

local Rational = require("core.rational")

-- Capture timeline draw calls so we can assert that gap edges render handles.
local original_timeline = timeline
local drawn_rects = {}
timeline = {
    get_dimensions = function(_) return 800, 120 end
    ,clear_commands = function() end
    ,add_rect = function(_, x, y, w, h, color)
        table.insert(drawn_rects, {x = x, y = y, w = w, h = h, color = color})
    end
    ,add_line = function() end
    ,add_text = function() end
    ,update = function() end
}

local state = {
    colors = {
        track_even = "#111111",
        track_odd = "#222222",
        grid_line = "#333333",
        mark_range_fill = "#000000",
        edge_selected_available = "#00ff00",
        edge_selected_limit = "#ff0000",
        playhead = "#ffffff",
    }
}

local prev_clip = {
    id = "clip_anchor",
    track_id = "track_v1",
    timeline_start = Rational.new(0, 1000, 1),
    duration = Rational.new(1000, 1000, 1)
}

local clip = {
    id = "clip_gap_target",
    track_id = "track_v1",
    timeline_start = Rational.new(2000, 1000, 1),
    duration = Rational.new(1000, 1000, 1)
}

function state.debug_begin_layout_capture() end
function state.debug_record_track_layout() end
function state.debug_record_clip_layout() end
function state.get_viewport_start_time() return Rational.new(0, 1000, 1) end
function state.get_viewport_duration() return Rational.new(5000, 1000, 1) end
function state.get_playhead_position() return Rational.new(0, 1000, 1) end
function state.get_mark_in() return nil end
function state.get_mark_out() return nil end
function state.get_sequence_id() return "default_sequence" end
function state.get_project_id() return "default_project" end
function state.get_sequence_frame_rate() return {fps_numerator = 1000, fps_denominator = 1} end
function state.get_clips() return {prev_clip, clip} end
function state.get_track_clip_index(track_id)
    if track_id ~= "track_v1" then
        return nil
    end
    return {prev_clip, clip}
end
function state.get_clip_by_id(clip_id)
    for _, c in ipairs(state.get_clips() or {}) do
        if c.id == clip_id then
            return c
        end
    end
    return nil
end
function state.get_selected_clips() return {} end
state._selected_edges = {}
function state.get_selected_edges()
    return state._selected_edges
end
function state.get_all_tracks() return {{id = "track_v1"}} end
function state.time_to_pixel(time_rational, width)
    local frames = time_rational.frames or 0
    local duration_frames = state.get_viewport_duration().frames
    return math.floor((frames / duration_frames) * width)
end
function state.get_track_heights() return {} end

local view = {
    widget = {},
    state = state,
    filtered_tracks = {{id = "track_v1"}},
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 80}
        },
        by_id = {
            track_v1 = {y = 0, height = 80}
        }
    },
    debug_id = "test-view"
}

function view.update_layout_cache() end
function view.get_track_visual_height()
    return 80
end
function view.get_track_id_at_y()
    return "track_v1"
end
function view.get_track_y_by_id()
    return 0
end

local renderer = require("ui.timeline.view.timeline_view_renderer")

local function render_for_edge(edge_entry)
    state._selected_edges = {edge_entry}
    drawn_rects = {}
    renderer.render(view)

    local handle_rects = {}
    for _, rect in ipairs(drawn_rects) do
        if rect.color == state.colors.edge_selected_available and rect.w >= 2 then
            table.insert(handle_rects, rect)
        end
    end
    assert(#handle_rects > 0, "selected edge should render at least one handle rect")
    return handle_rects
end

local clip_gap_edge = {clip_id = clip.id, edge_type = "gap_before", trim_type = "ripple"}
local clip_gap_rects = render_for_edge(clip_gap_edge)

local temp_gap_edge = {clip_id = "temp_gap_track_v1_0_2000", edge_type = "gap_before", track_id = "track_v1", trim_type = "ripple"}
render_for_edge(temp_gap_edge) -- should not error; verifies temp gap edges render

local function get_handle_bounds(rects)
    local min_x, max_x = math.huge, -math.huge
    for _, rect in ipairs(rects) do
        min_x = math.min(min_x, rect.x)
        max_x = math.max(max_x, rect.x + rect.w)
    end
    return min_x, max_x
end

local function assert_extends_into_gap(rects, boundary_px, direction, label)
    local min_x, max_x = get_handle_bounds(rects)
    if direction == "left" then
        assert(max_x <= boundary_px, string.format("%s handle should stay on or left of boundary (boundary=%d, max_x=%d)", label, boundary_px, max_x))
    else
        assert(min_x >= boundary_px, string.format("%s handle should stay on or right of boundary (boundary=%d, min_x=%d)", label, boundary_px, min_x))
    end
end

local width = 800
local gap_before_boundary = state.time_to_pixel(clip.timeline_start, width)
assert_extends_into_gap(clip_gap_rects, gap_before_boundary, "left", "gap_before")

local clip_gap_after_edge = {clip_id = prev_clip.id, edge_type = "gap_after", trim_type = "ripple"}
local clip_gap_after_rects = render_for_edge(clip_gap_after_edge)
local gap_after_boundary = state.time_to_pixel(prev_clip.timeline_start + prev_clip.duration, width)
assert_extends_into_gap(clip_gap_after_rects, gap_after_boundary, "right", "gap_after")

timeline = original_timeline

print("✅ timeline view renders handles for selected gap edges with correct orientation, including temp_gap_* ids")
