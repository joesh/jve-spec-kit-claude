#!/usr/bin/env luajit

-- Regression: when the timeline is zoomed very far out (pixels_per_frame << 1),
-- a clip that is inside the viewport by frame-level bounds must draw at least
-- one visible pixel on every scroll step.
--
-- Previously, the renderer would cull sub-pixel clips near the viewport edges
-- because the independent flooring of start/end pixel positions, combined
-- with the negative-x visible_width clip, could yield visible_width == 0.
-- As viewport_start scrolled one frame at a time, whether the clip's
-- sub-pixel extent crossed a whole-pixel boundary toggled → the clip flashed.
--
-- Domain assertion: for a clip whose frame-level overlap with the viewport is
-- non-empty (clip_end > viewport_start AND clip_start < viewport_end), at
-- least one add_rect call must reach the draw backend at every scroll step.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Capture add_rect calls to count clip bodies drawn per render.
local draw_calls = {}
_G.timeline = {
    get_dimensions = function() return 1920, 200 end,
    clear_commands = function() end,
    add_rect = function(_w, x, y, width, height, color)
        table.insert(draw_calls, { x = x, y = y, width = width, height = height, color = color })
    end,
    add_line = function() end,
    add_text = function() end,
    add_waveform = function() end,
    update = function() end,
}
_G.qt_set_widget_cursor = function() end

-- State stub: a few short clips on one track, deep zoom-out
local seq_rate = { fps_numerator = 24, fps_denominator = 1 }
-- Zoomed so that 1 frame = 1920 / 100000 ≈ 0.0192 px (highly sub-pixel).
local VIEWPORT_DURATION = 100000

-- One clip that's slightly inside the viewport. We scroll viewport_start
-- past the clip's start so the clip straddles the viewport's left edge —
-- this is where the negative-x + sub-pixel culling bug bites.
-- 5-frame clip at 5000..5005; we'll scroll viewport_start from ~4990..5050.
local clips = {
    { id = "c1", track_id = "v1", timeline_start = 5000, duration = 5, enabled = true, clip_kind = "video" },
}

local viewport_start_time = 0

local state = {
    colors = {
        mark_range_fill = "#000", grid_line = "#000", track_even = "#000",
        track_odd = "#000", clip_video = "#548bb5", clip_audio = "#000",
        clip_disabled_text = "#000", text = "#fff", playhead = "#000",
        edge_selected_available = "#000", edge_selected_limit = "#000",
        clip = "#000", clip_video_offline = "#000", clip_audio_offline = "#000",
        clip_offline_text = "#000", clip_video_disabled = "#555",
        clip_audio_disabled = "#555", clip_selected = "#ff8c42",
        clip_boundary = "#000",
    },
    get_viewport_start_time = function() return viewport_start_time end,
    get_viewport_duration = function() return VIEWPORT_DURATION end,
    get_playhead_position = function() return -1 end,  -- offscreen; irrelevant for this test
    get_mark_in = function() return nil end,
    get_mark_out = function() return nil end,
    get_sequence_frame_rate = function() return seq_rate end,
    get_selected_clips = function() return {} end,
    get_selected_edges = function() return {} end,
    get_selected_gaps = function() return {} end,
    get_all_tracks = function()
        return { { id = "v1", track_type = "VIDEO" } }
    end,
    get_track_clip_index = function(track_id)
        if track_id ~= "v1" then return nil end
        return clips
    end,
    time_to_pixel = function(t, width)
        local delta = (t or 0) - viewport_start_time
        local px_per_frame = width / VIEWPORT_DURATION
        return math.floor(delta * px_per_frame)
    end,
    debug_begin_layout_capture = function() end,
    debug_record_track_layout = function() end,
    get_active_edge_drag_state = function() return nil end,
    get_active_clip_drag_state = function() return nil end,
}

local view = {
    widget = {},
    state = state,
    debug_id = "test",
    filtered_tracks = { { id = "v1", track_type = "VIDEO" } },
    track_layout_cache = {
        by_index = { { y = 0, height = 100, track_type = "VIDEO" } },
        by_id = { v1 = { y = 0, height = 100, track_type = "VIDEO" } },
    },
    update_layout_cache = function() end,
    get_track_y_by_id = function(_, id)
        if id == "v1" then return 0, 100 end
    end,
}

local renderer = require("ui.timeline.view.timeline_view_renderer")

-- Count how many clip bodies were drawn in this render. Clip bodies use
-- clip_video color; other rects (track backgrounds, etc.) use different colors.
local function count_clip_bodies()
    local n = 0
    for _, c in ipairs(draw_calls) do
        if c.color == "#548bb5" then n = n + 1 end
    end
    return n
end

-- =============================================================================
-- Scroll viewport_start from 4990 to 5050 (crossing the clip). At every step,
-- frame-level overlap is non-empty → the clip MUST draw at least one pixel.
-- =============================================================================
local total_steps = 0
local missing_steps = 0
for vs = 4990, 5050 do
    viewport_start_time = vs
    draw_calls = {}
    renderer.render(view)
    total_steps = total_steps + 1
    local drawn = count_clip_bodies()

    -- Frame-level overlap: clip [5000..5005] intersects [vs..vs+VP_DUR]?
    -- vs+VP_DUR is always > 5005 (huge viewport), so overlap when vs < 5005.
    local clip_should_be_visible = (vs < 5005)
    if clip_should_be_visible and drawn == 0 then
        missing_steps = missing_steps + 1
        if missing_steps <= 5 then
            print(string.format("  STEP vs=%d drew %d clips (expected ≥1)", vs, drawn))
        end
    end
end

assert(missing_steps == 0,
    string.format("%d/%d scroll steps dropped a visible clip — sub-pixel cull regression",
        missing_steps, total_steps))

print(string.format("  PASS: all %d scroll steps drew the visible clip", total_steps))
print("\n✅ test_clip_flash_zoomed_out.lua passed")
