#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local timeline_view_input = require("ui.timeline.view.timeline_view_input")
local edge_picker = require("ui.timeline.edge_picker")
local time_utils = require("core.time_utils")
local keyboard_shortcuts = require("core.keyboard_shortcuts")

-- Initialize DB for command execution
local db_path = "/tmp/jve/test_timeline_edge_drag_frames_only.db"
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

local clips = {
    {
        id = "clip_a",
        track_id = "track_v1",
        timeline_start = 0,
        duration = 50
    },
    {
        id = "clip_b",
        track_id = "track_v1",
        timeline_start = 60,
        duration = 40
    }
}

-- Shared mock edge storage
local mock_edges = {}

-- Mock timeline_state module for SelectEdges command
timeline_state.get_selected_edges = function() return mock_edges end
timeline_state.set_edge_selection = function(edges) mock_edges = edges or {} end
timeline_state.get_clip_by_id = function(clip_id)
    for _, clip in ipairs(clips) do
        if clip.id == clip_id then return clip end
    end
    return nil
end

local function new_state()
    local state = {}

    state.get_selected_edges = function() return mock_edges end
    state.set_edge_selection = function(edges) mock_edges = edges or {} end
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
    state.get_track_clip_index = function() return clips end
    state.get_all_tracks = function() return {{id = "track_v1", track_type = "VIDEO"}} end
    state.get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end
    state.get_viewport_duration = function() return 100 end
    state.pixel_to_time = function(x) return x end
    state.time_to_pixel = function(time_value) return time_value end
    state.get_playhead_position = function() return 0 end
    state.clear_edge_selection = function() mock_edges = {} end
    state.clear_gap_selection = function() end
    state.set_selection = function() end
    state.get_clip_by_id = function(clip_id)
        for _, clip in ipairs(clips) do
            if clip.id == clip_id then return clip end
        end
        return nil
    end
    state.set_active_edge_drag_state = function() end
    state.is_dragging_playhead = function() return false end
    state.set_dragging_playhead = function() end
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

local edge = {clip_id = "clip_b", edge_type = "gap_before", trim_type = "ripple", track_id = "track_v1"}

local original_pick_edges = edge_picker.pick_edges
local original_to_ms = time_utils.to_milliseconds
local original_snapping = keyboard_shortcuts.is_snapping_enabled

edge_picker.pick_edges = function()
    return {
        selection = {edge},
        zone = "left",
        dragged_edge = edge
    }
end

time_utils.to_milliseconds = function()
    error("edge drag should not use milliseconds", 2)
end
keyboard_shortcuts.is_snapping_enabled = function()
    return false
end

local view = new_view(new_state())
timeline_view_input.handle_mouse(view, "press", 10, 10, 1, nil)
timeline_view_input.handle_mouse(view, "move", 25, 10, 1, nil)

edge_picker.pick_edges = original_pick_edges
time_utils.to_milliseconds = original_to_ms
keyboard_shortcuts.is_snapping_enabled = original_snapping

assert(view.drag_state, "drag_state should be created on move")
assert(view.drag_state.delta_frames == 15,
    "delta_frames should track frame delta without milliseconds")

print("✅ Edge drag updates use frame deltas only")
