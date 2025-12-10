#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

local Rational = require("core.rational")
local renderer = require("ui.timeline.view.timeline_view_renderer")
local command_manager = require("core.command_manager")

local original_get_executor = command_manager.get_executor
local captured_lead = nil

command_manager.get_executor = function()
    return function(cmd)
        captured_lead = cmd:get_parameter("lead_edge")
        return {planned_mutations = {}}
    end
end

local function rational(frames)
    return Rational.new(frames, 24, 1)
end

local clips = {
    {id = "clip_left", track_id = "track_v1", timeline_start = rational(0), duration = rational(240)},
    {id = "clip_right", track_id = "track_v2", timeline_start = rational(480), duration = rational(240)}
}

local state = {
    colors = {
        track_even = "#111111",
        track_odd = "#222222",
        grid_line = "#333333",
        clip_video = "#555555",
        text = "#ffffff",
        clip_selected = "#00ff00",
        clip = "#222222",
        playhead = "#ff00ff",
        edge_selected_available = "#00ff00",
        edge_selected_limit = "#ff0000",
        gap_selected_outline = "#ffff00"
    },
    dimensions = {
        clip_outline_thickness = 4
    }
}

state.debug_begin_layout_capture = function() end
state.debug_record_track_layout = function() end
state.debug_record_clip_layout = function() end
state.get_viewport_start_time = function() return rational(0) end
state.get_viewport_duration = function() return rational(960) end
state.get_playhead_position = function() return rational(0) end
state.get_mark_in = function() return nil end
state.get_mark_out = function() return nil end
state.get_sequence_id = function() return "seq_lead_test" end
state.get_project_id = function() return "proj_lead_test" end
state.get_sequence_frame_rate = function() return {fps_numerator = 24, fps_denominator = 1} end
state.get_clips = function() return clips end
state.get_selected_clips = function() return {} end
state.get_selected_edges = function() return {} end
state.get_all_tracks = function()
    return {
        {id = "track_v1"},
        {id = "track_v2"}
    }
end
state.get_track_heights = function() return {} end
state.time_to_pixel = function(time_value, width)
    local frames = time_value.frames or 0
    local duration_frames = state.get_viewport_duration().frames
    return math.floor((frames / duration_frames) * width)
end

local view = {
    widget = {},
    state = state,
    filtered_tracks = {
        {id = "track_v1"},
        {id = "track_v2"}
    },
    track_layout_cache = {
        by_index = {
            [1] = {y = 0, height = 80},
            [2] = {y = 90, height = 80},
        },
        by_id = {
            track_v1 = {y = 0, height = 80},
            track_v2 = {y = 90, height = 80}
        }
    },
    debug_id = "lead-edge-preview-test"
}

function view.update_layout_cache() end
function view.get_track_visual_height(_, track_id)
    return (track_id == "track_v1" or track_id == "track_v2") and 80 or 80
end
function view.get_track_id_at_y(_, y)
    if y < 80 then return "track_v1" end
    return "track_v2"
end
function view.get_track_y_by_id(_, track_id)
    if track_id == "track_v1" then return 0 end
    if track_id == "track_v2" then return 90 end
    return -1
end

view.drag_state = {
    type = "edges",
    edges = {
        {clip_id = "clip_left", edge_type = "out", track_id = "track_v1", trim_type = "ripple"},
        {clip_id = "clip_right", edge_type = "in", track_id = "track_v2", trim_type = "ripple"}
    },
    lead_edge = {clip_id = "clip_right", edge_type = "in", track_id = "track_v2", trim_type = "ripple"},
    delta_rational = rational(24),
    preview_data = nil
}

_G.timeline = {
    get_dimensions = function() return 800, 200 end,
    clear_commands = function() end,
    add_rect = function() end,
    add_line = function() end,
    add_text = function() end,
    update = function() end
}

local ok, err = pcall(function()
    renderer.render(view)
end)

command_manager.get_executor = original_get_executor

assert(ok, "renderer.render should not error: " .. tostring(err))
assert(captured_lead, "renderer should pass lead_edge to preview command")
assert(captured_lead.clip_id == "clip_right", "lead edge clip_id should match drag state")
assert(captured_lead.edge_type == "in", "lead edge type should match drag state")

print("✅ Edge preview dry runs respect the dragged lead edge")
