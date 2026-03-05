#!/usr/bin/env luajit
-- NSF test: renderer draws correct label prefix for offline vs codec unavailable clips.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local function check(desc, cond)
    if not cond then error("FAIL: " .. desc) end
    print("  OK: " .. desc)
end

-- Capture add_text calls
local captured_texts = {}
_G.timeline = {
    get_dimensions = function() return 800, 200 end,
    clear_commands = function() captured_texts = {} end,
    add_rect = function() end,
    add_line = function() end,
    add_text = function(_, _, _, text)
        captured_texts[#captured_texts + 1] = text
    end,
    update = function() end,
}

local seq_rate = { fps_numerator = 24, fps_denominator = 1 }

local function make_state(clips_by_track)
    return {
        colors = {
            mark_range_fill = "#000",
            grid_line = "#000",
            track_even = "#000",
            track_odd = "#000",
            clip_video = "#00f",
            clip_audio = "#0f0",
            clip_video_offline = "#f00",
            clip_audio_offline = "#f00",
            clip_offline_text = "#fff",
            clip_disabled_text = "#888",
            text = "#fff",
            playhead = "#f00",
            edge_selected_available = "#0f0",
            edge_selected_limit = "#f00",
            clip = "#333",
            clip_selected = "#ff0",
        },
        get_viewport_start_time = function() return 0 end,
        get_viewport_duration = function() return 200 end,
        get_playhead_position = function() return 0 end,
        get_mark_in = function() return nil end,
        get_mark_out = function() return nil end,
        get_sequence_frame_rate = function() return seq_rate end,
        time_to_pixel = function(t, width)
            return ((t or 0) / 200) * width
        end,
        get_clips = function()
            error("get_clips must not be called", 2)
        end,
        get_selected_clips = function() return {} end,
        get_selected_edges = function() return {} end,
        get_selected_gaps = function() return {} end,
        get_all_tracks = function()
            return { { id = "v1", track_type = "VIDEO" } }
        end,
        debug_begin_layout_capture = function() end,
        debug_record_track_layout = function() end,
        get_track_clip_index = function(track_id)
            return clips_by_track[track_id] or {}
        end,
    }
end

local function make_view(state_mod)
    return {
        widget = {},
        state = state_mod,
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
        get_track_y_by_id = function(_, track_id)
            if track_id == "v1" then return 0 end
            return -1
        end,
        get_track_visual_height = function(_, track_id)
            if track_id == "v1" then return 100 end
            return 0
        end,
    }
end

local renderer = require("ui.timeline.view.timeline_view_renderer")

-- ============================================================
print("\n--- renderer: offline file shows 'OFFLINE - ' prefix ---")
do
    local clips = {
        {
            id = "c1", track_id = "v1", label = "MyClip",
            timeline_start = 0, duration = 100,
            enabled = true, offline = true, error_code = "FileNotFound",
        },
    }
    local st = make_state({ v1 = clips })
    local view = make_view(st)

    captured_texts = {}
    renderer.render(view)

    local found = false
    for _, text in ipairs(captured_texts) do
        if text:find("^OFFLINE %- ") then
            found = true
            check("label starts with 'OFFLINE - '", true)
            check("label contains clip name", text:find("MyClip") ~= nil)
            break
        end
    end
    check("found OFFLINE label in rendered text", found)
end

-- ============================================================
print("\n--- renderer: codec unavailable shows 'CODEC UNAVAIL - ' prefix ---")
do
    local clips = {
        {
            id = "c2", track_id = "v1", label = "BRAWClip",
            timeline_start = 0, duration = 100,
            enabled = true, offline = true, error_code = "Unsupported",
        },
    }
    local st = make_state({ v1 = clips })
    local view = make_view(st)

    captured_texts = {}
    renderer.render(view)

    local found = false
    for _, text in ipairs(captured_texts) do
        if text:find("^CODEC UNAVAIL %- ") then
            found = true
            check("label starts with 'CODEC UNAVAIL - '", true)
            check("label contains clip name", text:find("BRAWClip") ~= nil)
            break
        end
    end
    check("found CODEC UNAVAIL label in rendered text", found)
end

-- ============================================================
print("\n--- renderer: DecodeFailed also shows 'CODEC UNAVAIL - ' prefix ---")
do
    local clips = {
        {
            id = "c3", track_id = "v1", label = "CorruptClip",
            timeline_start = 0, duration = 100,
            enabled = true, offline = true, error_code = "DecodeFailed",
        },
    }
    local st = make_state({ v1 = clips })
    local view = make_view(st)

    captured_texts = {}
    renderer.render(view)

    local found = false
    for _, text in ipairs(captured_texts) do
        if text:find("^CODEC UNAVAIL %- ") then
            found = true
            break
        end
    end
    check("DecodeFailed maps to CODEC UNAVAIL prefix", found)
end

-- ============================================================
print("\n--- renderer: online clip has no prefix ---")
do
    local clips = {
        {
            id = "c4", track_id = "v1", label = "NormalClip",
            timeline_start = 0, duration = 100,
            enabled = true, offline = false, error_code = nil,
        },
    }
    local st = make_state({ v1 = clips })
    local view = make_view(st)

    captured_texts = {}
    renderer.render(view)

    local found_prefix = false
    for _, text in ipairs(captured_texts) do
        if text:find("^OFFLINE") or text:find("^CODEC") then
            found_prefix = true
        end
    end
    check("online clip has no offline/codec prefix", found_prefix == false)
end

print("\n✅ test_timeline_renderer_codec_label.lua passed")
