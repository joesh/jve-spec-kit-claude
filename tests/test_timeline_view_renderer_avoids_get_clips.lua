#!/usr/bin/env luajit
-- Regression: timeline_view_renderer should not scan state.get_clips() when
-- per-track indices are available (get_track_clip_index).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local Rational = require("core.rational")

-- Stub timeline drawing backend
_G.timeline = {
    get_dimensions = function() return 800, 200 end,
    clear_commands = function() end,
    add_rect = function() end,
    add_line = function() end,
    add_text = function() end,
    update = function() end,
}

local seq_rate = { fps_numerator = 24, fps_denominator = 1 }

local clips = {
    { id = "c1", track_id = "v1", timeline_start = Rational.new(0, 24, 1), duration = Rational.new(24, 24, 1), enabled = true },
    { id = "c2", track_id = "v1", timeline_start = Rational.new(48, 24, 1), duration = Rational.new(24, 24, 1), enabled = true },
}

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
        clip_selected = "#000",
    },
    get_viewport_start_time = function() return Rational.new(0, 24, 1) end,
    get_viewport_duration = function() return Rational.new(96, 24, 1) end,
    get_playhead_position = function() return Rational.new(0, 24, 1) end,
    get_mark_in = function() return nil end,
    get_mark_out = function() return nil end,
    get_sequence_frame_rate = function() return seq_rate end,
    get_clips = function()
        error("state.get_clips should not be called by renderer when get_track_clip_index is present", 2)
    end,
    get_track_clip_index = function(track_id)
        if track_id ~= "v1" then return nil end
        return clips
    end,
    get_selected_clips = function() return {} end,
    get_selected_edges = function() return {} end,
    get_selected_gaps = function() return {} end,
    get_all_tracks = function() return { { id = "v1", track_type = "VIDEO" } } end,
    time_to_pixel = function(rt, width)
        local frames = rt and rt.frames or 0
        local duration_frames = 96
        return math.floor((frames / duration_frames) * width)
    end,
    debug_begin_layout_capture = function() end,
    debug_record_track_layout = function() end,
    debug_record_clip_layout = function() end,
}

local view = {
    widget = {},
    state = state,
    debug_id = "test",
    filtered_tracks = { { id = "v1", track_type = "VIDEO" } },
    track_layout_cache = {
        by_index = {
            { y = 0, height = 100, track_type = "VIDEO" },
        },
        by_id = {
            v1 = { y = 0, height = 100, track_type = "VIDEO" },
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
renderer.render(view)

print("✅ timeline_view_renderer renders without calling state.get_clips when track indices exist")

