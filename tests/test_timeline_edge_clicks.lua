#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local timeline_view_input = require("ui.timeline.view.timeline_view_input")
local edge_picker = require("ui.timeline.edge_picker")

-- Initialize DB for command execution
local db_path = "/tmp/jve/test_timeline_edge_clicks.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, now, now))

command_manager.init("seq1", "proj1")

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

-- Shared mock edge storage (command writes to timeline_state, test reads from here)
local mock_edges = {}
local mock_set_calls = 0

-- Mock timeline_state module for SelectEdges command
timeline_state.get_selected_edges = function() return mock_edges end
timeline_state.set_edge_selection = function(edges)
    mock_set_calls = mock_set_calls + 1
    mock_edges = {}
    for _, edge in ipairs(edges or {}) do
        table.insert(mock_edges, clone_edge(edge))
    end
end
timeline_state.get_clip_by_id = function(clip_id)
    return { id = clip_id, track_id = "track_v1" }
end

local function new_state(clips)
    local state = {
        _clips = clips or {},
    }

    -- Expose mock state for test assertions
    state.get_selected_edges = function() return mock_edges end
    state.get_set_calls = function() return mock_set_calls end
    state.reset_set_calls = function() mock_set_calls = 0 end

    state.set_edge_selection = function(edges)
        mock_set_calls = mock_set_calls + 1
        mock_edges = {}
        for _, edge in ipairs(edges or {}) do
            table.insert(mock_edges, clone_edge(edge))
        end
    end

    state.toggle_edge_selection = function(clip_id, edge_type, trim_type)
        for idx, edge in ipairs(mock_edges) do
            if edge.clip_id == clip_id and edge.edge_type == edge_type then
                table.remove(mock_edges, idx)
                return
            end
        end
        table.insert(mock_edges, {
            clip_id = clip_id,
            edge_type = edge_type,
            trim_type = trim_type or "ripple",
            track_id = "track_v1"
        })
    end

    state.get_clips = function() return state._clips end
    state.get_track_clip_index = function(track_id)
        local list = {}
        for _, clip in ipairs(state._clips) do
            if clip.track_id == track_id then
                list[#list + 1] = clip
            end
        end
        return list
    end
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
    state.clear_edge_selection = function() mock_edges = {} end
    state.clear_gap_selection = function() end
    state.set_selection = function() end
    state.get_project_id = function() return "proj1" end
    state.get_sequence_id = function() return "seq1" end

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
local view1 = new_view(state1)

with_pick({selection = {edge_a}, zone = "left", dragged_edge = edge_a}, function()
    timeline_view_input.handle_mouse(view1, "press", 10, 10, 1, nil)
end)

-- Clicking already-selected edge preserves the full selection (for drag initiation)
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
