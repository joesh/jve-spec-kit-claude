#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

local timeline_view_input = require("ui.timeline.view.timeline_view_input")
local edge_picker = require("ui.timeline.edge_picker")

_G.timeline = {
    get_dimensions = function() return 1000, 100 end
}

local function clone_edge(edge)
    return {
        clip_id = edge.clip_id,
        edge_type = edge.edge_type,
        trim_type = edge.trim_type,
        track_id = edge.track_id
    }
end

local function new_state(clips)
    local state = {
        _selected_edges = {},
        _clips = clips or {},
        set_calls = 0
    }

    state.get_selected_edges = function()
        return state._selected_edges
    end

    state.set_edge_selection = function(edges)
        state.set_calls = state.set_calls + 1
        state._selected_edges = {}
        for _, edge in ipairs(edges or {}) do
            table.insert(state._selected_edges, clone_edge(edge))
        end
    end

    state.toggle_edge_selection = function(clip_id, edge_type, trim_type)
        for idx, edge in ipairs(state._selected_edges) do
            if edge.clip_id == clip_id and edge.edge_type == edge_type then
                table.remove(state._selected_edges, idx)
                return
            end
        end
        table.insert(state._selected_edges, {
            clip_id = clip_id,
            edge_type = edge_type,
            trim_type = trim_type or "ripple",
            track_id = "track_v1"
        })
    end

    state.get_clips = function() return state._clips end
    state.get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end
    state.get_viewport_duration = function() return 100 end
    state.pixel_to_time = function() return {frames = 0, fps_numerator = 24, fps_denominator = 1} end
    state.time_to_pixel = function(time_value)
        if type(time_value) == "table" then
            return time_value.frames or 0
        end
        return time_value or 0
    end
    state.get_playhead_position = function() return {frames = 0, fps_numerator = 24, fps_denominator = 1} end
    state.clear_edge_selection = function() state._selected_edges = {} end
    state.clear_gap_selection = function() end
    state.set_selection = function() end

    return state
end

local function new_view(state)
    return {
        widget = {},
        state = state,
        render = function() end,
        get_track_id_at_y = function() return "track_v1" end,
        get_track_y_by_id = function() return 0 end,
        get_track_visual_height = function() return 80 end
    }
end

local original_pick_edges = edge_picker.pick_edges

local function with_pick(result, fn)
    assert(result.dragged_edge, "tests must specify dragged_edge in pick result")
    edge_picker.pick_edges = function() return result end
    local ok, err = pcall(fn)
    edge_picker.pick_edges = original_pick_edges
    assert(ok, err)
end

local edge_a = {clip_id = "clip_a", edge_type = "gap_before", trim_type = "ripple", track_id = "track_v1"}
local edge_b = {clip_id = "clip_b", edge_type = "gap_before", trim_type = "ripple", track_id = "track_v1"}

-- Test 1: clicking without modifiers on an already-selected edge leaves selection intact
local track_clips = {
    {id = "clip_a", track_id = "track_v1", timeline_start = 0, duration = 10},
    {id = "clip_b", track_id = "track_v1", timeline_start = 20, duration = 10}
}

local state1 = new_state(track_clips)
state1.set_edge_selection({edge_a, edge_b})
state1.set_calls = 0
local view1 = new_view(state1)

with_pick({selection = {edge_a}, zone = "left", dragged_edge = edge_a}, function()
    timeline_view_input.handle_mouse(view1, "press", 10, 10, 1, nil)
end)

assert(state1.set_calls == 0, "clicking existing selection should not call set_edge_selection")
assert(#state1:get_selected_edges() == 2, "existing selection should remain untouched")

-- Test 2: Shift modifier toggles the clicked edge just like Command
local state2 = new_state(track_clips)
state2.set_edge_selection({edge_a})
local view2 = new_view(state2)

with_pick({selection = {edge_b}, zone = "left", dragged_edge = edge_b}, function()
    timeline_view_input.handle_mouse(view2, "press", 12, 12, 1, {shift = true})
end)

local selections = state2:get_selected_edges()
assert(#selections == 2, "Shift-click should toggle a new edge into selection")

-- Test 3: dragged edge always becomes lead edge even if selection order differs
local state3 = new_state(track_clips)
state3.set_edge_selection({edge_a, edge_b})
local view3 = new_view(state3)

with_pick({selection = {edge_a, edge_b}, zone = "right", dragged_edge = edge_b}, function()
    timeline_view_input.handle_mouse(view3, "press", 15, 15, 1, nil)
end)

assert(view3.potential_drag, "press should initialize potential drag")
assert(view3.potential_drag.lead_edge.clip_id == edge_b.clip_id,
    "Lead edge should track the dragged edge even when selection order differs")

print("✅ Timeline edge clicks preserve selection, support Shift toggling, and honor dragged-edge leadership")
