#!/usr/bin/env luajit
-- Contract: a clip in the track index that is missing sequence_start /
-- duration is a corrupt index — every clip is integer-coord today (see
-- CLAUDE.md "All coords are integers"). The renderer MUST assert
-- loudly rather than silently render nothing (NSF: no silent failures).
--
-- This test originally pinned the opposite (silent tolerance, dating
-- to a Rational-coord migration era when these fields could legitimately
-- be nil). That migration is complete; the legacy contract is gone.

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
    get_mark_in          = function() return nil end,
    get_mark_out         = function() return nil end,
    get_display_mark_in  = function() return nil end,
    get_display_mark_out = function() return nil end,
    get_ghost_mark       = function() return nil end,
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
require("test_env").attach_strip_to_state_mock(state)

state.get_track_clip_index = function(track_id)
    if track_id ~= "v1" then
        return nil
    end
    return {
        { id = "clip_missing_fields", track_id = "v1", sequence_start = nil, duration = nil, enabled = true },
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
assert(not ok,
    "renderer.render must REJECT a track-clip index entry with nil "
    .. "sequence_start (NSF: corrupt index must surface, not be silently "
    .. "tolerated). The render call succeeded.")
assert(tostring(err):find("sequence_start", 1, true),
    "Assert must name the corrupt field. Got: " .. tostring(err))
assert(tostring(err):find("clip_missing_fields", 1, true),
    "Assert must name the offending clip id for actionable diagnostics. "
    .. "Got: " .. tostring(err))

print("✅ timeline_view_renderer asserts on corrupt clip-index entries")
