#!/usr/bin/env luajit
-- Regression: timeline_view_renderer must not crash when clips are missing timeline_start/duration (Rational).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Stub timeline drawing backend
_G.timeline = {
    get_dimensions = function() return 800, 200 end,
    clear_commands = function() end,
    add_rect = function() end,
    add_line = function() end,
    add_text = function() end,
    update = function() end,
}

-- Minimal state module stub
local seq_rate = { fps_numerator = 24, fps_denominator = 1 }
local state = {
    colors = {
        mark_range_fill = "#000",
        grid_line = "#000",
        track_even = "#000",
        track_odd = "#000",
        clip_video = "#000",
        clip_audio = "#000",
        clip_disabled_text = "#000",
        text = "#000",
        playhead = "#000",
        edge_selected_available = "#000",
        edge_selected_limit = "#000",
        clip = "#000",
    },
    get_viewport_start_time = function() return 0 end,
    get_viewport_duration = function() return 100 end,
    get_playhead_position = function() return 0 end,
    get_mark_in = function() return nil end,
    get_mark_out = function() return nil end,
    get_sequence_frame_rate = function() return seq_rate end,
    time_to_pixel = function(t, width)
        local frames = t or 0
        return (frames / (seq_rate.fps_numerator or 24)) * (width / 100)
    end,
    get_clips = function()
        error("test_timeline_view_renderer_missing_clip_fields: get_clips must not be used during base render", 2)
    end,
    get_selected_clips = function() return {} end,
    get_selected_edges = function() return {} end,
    get_selected_gaps = function() return {} end,
    get_all_tracks = function()
        return { { id = "v1", track_type = "VIDEO" } }
    end,
    debug_begin_layout_capture = function() end,
    debug_record_track_layout = function() end,
}

state.get_track_clip_index = function(track_id)
    if track_id ~= "v1" then
        return nil
    end
    return {
        { id = "clip_missing_fields", track_id = "v1", timeline_start = nil, duration = nil, enabled = true },
    }
end

local view = {
    widget = {},
    state = state,
    debug_id = "test",
    filtered_tracks = { { id = "v1", track_type = "VIDEO" } },
    track_layout_cache = {
        by_index = {
            { y = 0, height = 100, track_type = "VIDEO" }
        },
        by_id = {
            v1 = { y = 0, height = 100, track_type = "VIDEO" }
        }
    },
    update_layout_cache = function() end,
    get_track_y_by_id = function(_, track_id, _h)
        if track_id == "v1" then return 0 end
        return -1
    end,
    get_track_visual_height = function(_, track_id)
        if track_id == "v1" then return 100 end
        return 0
    end,
}

local renderer = require("ui.timeline.view.timeline_view_renderer")

local ok, err = pcall(renderer.render, view)
assert(ok, "renderer.render raised error for missing clip fields: " .. tostring(err))

print("✅ timeline_view_renderer tolerates clips missing timeline_start/duration")
