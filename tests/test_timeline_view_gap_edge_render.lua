#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

-- Capture timeline draw calls so we can assert that gap clip edges render handles.
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
        clip_boundary = "#000000",
    }
}
require("test_env").attach_strip_to_state_mock(state)

local prev_clip = {
    id = "clip_anchor",
    track_id = "track_v1",
    sequence_start = 0,
    duration = 1000
}

-- Gap clip between prev_clip and next_clip
local gap_clip = {
    id = "gap_track_v1_1000",
    track_id = "track_v1",
    sequence_start = 1000,
    duration = 1000,
    clip_kind = "gap"
}

local next_clip = {
    id = "clip_gap_target",
    track_id = "track_v1",
    sequence_start = 2000,
    duration = 1000
}

function state.debug_begin_layout_capture() end
function state.debug_record_track_layout() end
function state.debug_record_clip_layout() end
function state.get_viewport_start_time() return 0 end
function state.get_viewport_duration() return 5000 end
function state.get_playhead_position() return 0 end
function state.get_mark_in()          return nil end
function state.get_mark_out()         return nil end
function state.get_display_mark_in()  return nil end
function state.get_display_mark_out() return nil end
function state.get_ghost_mark()       return nil end
function state.get_sequence_id() return "default_sequence" end
function state.get_project_id() return "default_project" end
function state.get_sequence_frame_rate() return {fps_numerator = 1000, fps_denominator = 1} end
function state.get_clips() return {prev_clip, gap_clip, next_clip} end
function state.get_track_clip_index(track_id)
    if track_id ~= "track_v1" then
        return nil
    end
    return {prev_clip, gap_clip, next_clip}
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
function state.time_to_pixel(t, width)
    local frames = t or 0
    local duration_frames = state.get_viewport_duration()
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

-- Gap clip "in" edge (left boundary of gap)
local gap_in_edge = {clip_id = gap_clip.id, edge_type = "in", trim_type = "ripple"}
local gap_in_rects = render_for_edge(gap_in_edge)

-- Gap clip "out" edge (right boundary of gap)
local gap_out_edge = {clip_id = gap_clip.id, edge_type = "out", trim_type = "ripple"}
local gap_out_rects = render_for_edge(gap_out_edge)

local function get_handle_bounds(rects)
    local min_x, max_x = math.huge, -math.huge
    for _, rect in ipairs(rects) do
        min_x = math.min(min_x, rect.x)
        max_x = math.max(max_x, rect.x + rect.w)
    end
    return min_x, max_x
end

-- Verify in-edge handle is near the gap's left boundary
local width = 800
local gap_in_boundary = state.time_to_pixel(gap_clip.sequence_start, width)
local in_min, _ = get_handle_bounds(gap_in_rects)
assert(math.abs(in_min - gap_in_boundary) < 20,
    string.format("gap in-edge handle should be near gap start (boundary=%d, handle_min=%d)",
        gap_in_boundary, in_min))

-- Verify out-edge handle is near the gap's right boundary
local gap_out_boundary = state.time_to_pixel(gap_clip.sequence_start + gap_clip.duration, width)
local _, out_max = get_handle_bounds(gap_out_rects)
assert(math.abs(out_max - gap_out_boundary) < 20,
    string.format("gap out-edge handle should be near gap end (boundary=%d, handle_max=%d)",
        gap_out_boundary, out_max))

timeline = original_timeline

print("✅ timeline view renders handles for selected gap clip edges with correct orientation")
