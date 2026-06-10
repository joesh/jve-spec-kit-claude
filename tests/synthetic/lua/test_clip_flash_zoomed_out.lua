#!/usr/bin/env luajit

-- Regression: when the timeline is zoomed very far out (pixels_per_frame << 1),
-- a clip that has non-zero pixel width must draw consistently on every scroll
-- step — no flashing on/off as the viewport translates by whole frames.
--
-- Previously, time_to_pixel quantized to integer pixels, and the floor's
-- interaction with viewport_start made a fixed clip's pixel width strobe
-- ±1 px during scroll; clips whose visible_width collapsed to 0 flashed
-- off entirely.
--
-- Fix: time_to_pixel is the exact float map (t - vs) * ppf — no
-- quantization until the antialiased painter. Clip widths in pixel space
-- are invariant under scroll (within float noise), and sub-pixel clips
-- draw a 1px sliver instead of flashing.
--
-- Domain assertion: a clip with multi-pixel width at the current zoom
-- draws on every scroll step inside its visibility window, with the same
-- pixel width on every step.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Capture add_rect calls to count clip bodies drawn per render.
local draw_calls = {}
_G.timeline = {
    get_dimensions = function() return 1920, 200 end,
    set_pan_offset_px = function() end,
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

-- 500-frame clip at 5000..5500. At ppf ≈ 0.0192 this is ~9-10 absolute
-- px wide — comfortably above the cull threshold. Scroll viewport_start
-- across the clip's frame extent and verify width stays constant.
local CLIP_START = 5000
local CLIP_DURATION = 500
local clips = {
    { id = "c1", track_id = "v1", sequence_start = CLIP_START, duration = CLIP_DURATION, enabled = true, clip_kind = "video" },
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
    get_mark_in          = function() return nil end,
    get_mark_out         = function() return nil end,
    get_display_mark_in  = function() return nil end,
    get_display_mark_out = function() return nil end,
    get_ghost_mark       = function() return nil end,
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
        -- Mirrors production viewport_state.time_to_pixel: exact float map.
        local px_per_frame = width / VIEWPORT_DURATION
        return ((t or 0) - viewport_start_time) * px_per_frame
    end,
    debug_begin_layout_capture = function() end,
    debug_record_track_layout = function() end,
    get_active_edge_drag_state = function() return nil end,
    get_active_clip_drag_state = function() return nil end,
}
require("test_env").attach_strip_to_state_mock(state)

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

-- Find the clip body draw call for this render. Clip bodies use the
-- clip_video color; other rects use different colors.
local function clip_body_widths()
    local widths = {}
    for _, c in ipairs(draw_calls) do
        if c.color == "#548bb5" then table.insert(widths, c.width) end
    end
    return widths
end

-- Scroll viewport_start across the clip and assert the body draws on every
-- step where the clip overlaps the viewport, AND that its width is constant.
local total_steps = 0
local first_width
local mismatches = {}
local missing = {}
-- Keep the clip fully inside the viewport (vs ≤ CLIP_START) so we test
-- pure width invariance, separate from edge-clipping behavior.
for vs = 0, CLIP_START do
    viewport_start_time = vs
    draw_calls = {}
    renderer.render(view)
    total_steps = total_steps + 1

    local widths = clip_body_widths()
    local clip_end = CLIP_START + CLIP_DURATION
    local clip_should_be_visible = (vs < clip_end)

    if clip_should_be_visible then
        if #widths == 0 then
            table.insert(missing, vs)
        else
            local w = widths[1]
            if not first_width then first_width = w end
            -- Float draw coords: equal within arithmetic noise. A real
            -- strobe is a full ±1 px, five orders of magnitude larger.
            if math.abs(w - first_width) > 1e-6 then
                table.insert(mismatches, { vs = vs, w = w })
            end
        end
    end
end

if #missing > 0 then
    for i = 1, math.min(5, #missing) do
        print(string.format("  STEP vs=%d drew 0 clips (expected ≥1)", missing[i]))
    end
    error(string.format("%d/%d scroll steps dropped a visible clip", #missing, total_steps))
end

if #mismatches > 0 then
    print(string.format("first_width = %d", first_width))
    for i = 1, math.min(5, #mismatches) do
        print(string.format("  vs=%d width=%d (expected %d)",
            mismatches[i].vs, mismatches[i].w, first_width))
    end
    error(string.format("%d/%d scroll steps drew a different width — strobing",
        #mismatches, total_steps))
end

print(string.format("  PASS: all %d scroll steps drew width=%d", total_steps, first_width))
print("\n✅ test_clip_flash_zoomed_out.lua passed")
