--- A clip that overlaps the visible time window must always be drawn —
-- at minimum a one-pixel sliver — at EVERY zoom level. At far zoom-out
-- a clip's true pixel width rounds below one pixel, and the draw
-- decision must not flip with the zoom level: during a continuous zoom
-- drag the pixels-per-frame ratio changes every mouse move, and an
-- unstable decision makes sub-pixel clips strobe on/off (Joe's report,
-- 2026-06-09: thumb-drag zoom made clips flicker because whether they
-- were drawn wasn't stable).
--
-- Drives real zoom gestures (ZoomTimelineViewport, the same command the
-- zoom scroller's thumb-end drag dispatches) across a fine sweep of
-- viewport durations, and checks the renderer's horizontal-span
-- contract for clips at sub-pixel durations and odd positions: the
-- span must exist, be at least 1px wide, and lie within the track.
--
-- Run: ./build/bin/jve --test tests/synthetic/integration/test_clip_draw_stability.lua

local ui = require("synthetic.integration.ui_test_env")

print("=== test_clip_draw_stability ===")

local _, info = ui.launch({
    project_name = "Clip Draw Stability Test",
})
local db_path = info.db_path

local state = require("ui.timeline.timeline_state")
local renderer = require("ui.timeline.view.timeline_view_renderer")
local command_manager = require("core.command_manager")

ui.pump(300)

-- Narrow track width puts modest zoom levels in the sub-pixel regime:
-- at viewport durations around 1200-1330 frames, pixels-per-frame is
-- ~0.15-0.17, so clips up to ~6 frames are under one pixel wide.
local WIDTH = 200

-- Sub-pixel durations at odd offsets from the viewport start (frames).
-- Offsets are arbitrary non-round values so the clips land at varied
-- positions relative to the pixel grid as the zoom sweeps.
local CLIPS = {
    { offset = 301, duration = 2 },
    { offset = 487, duration = 3 },
    { offset = 555, duration = 5 },
    { offset = 700, duration = 1 },
}

local function zoom_to(duration_frames)
    local vstart = state.get_viewport_start_time()
    assert(vstart, "no visible time window")
    command_manager.execute("ZoomTimelineViewport", {
        duration_frames = duration_frames,
        anchor_frame = vstart,
    })
end

local failures = {}
local checked = 0

for viewport_duration = 1200, 1330 do
    zoom_to(viewport_duration)
    local vstart = state.get_viewport_start_time()
    local vend = vstart + state.get_viewport_duration()
    for _, c in ipairs(CLIPS) do
        local clip_start = vstart + c.offset
        -- Only assert for clips fully inside the visible window.
        if clip_start + c.duration < vend then
            checked = checked + 1
            local visible_x, draw_width =
                renderer.clip_h_span(state, clip_start, c.duration, WIDTH)
            if not visible_x or draw_width < 1 then
                failures[#failures + 1] = string.format(
                    "viewport=%d frames: clip at +%d (%d frames) not drawn (span=%s)",
                    viewport_duration, c.offset, c.duration,
                    tostring(draw_width))
            else
                assert(visible_x >= 0 and visible_x < WIDTH, string.format(
                    "viewport=%d frames: clip at +%d drawn outside the track "
                    .. "(x=%d width=%d track=%d)",
                    viewport_duration, c.offset, visible_x, draw_width, WIDTH))
            end
        end
    end
end

assert(checked > 400, string.format(
    "test setup: expected a dense sweep, only %d cases checked", checked))
assert(#failures == 0, string.format(
    "%d of %d visible-clip cases were not drawn — sub-pixel clips strobe "
    .. "during zoom. First few:\n  %s",
    #failures, checked,
    table.concat({ failures[1], failures[2], failures[3] }, "\n  ")))
print(string.format("  all %d visible-clip cases drawn (>=1px) across the zoom sweep", checked))

-- A clip whose last frame is the last visible frame must occupy the
-- final pixel column, not vanish off the right edge.
do
    zoom_to(1280)
    local vstart = state.get_viewport_start_time()
    local vend = vstart + state.get_viewport_duration()
    local visible_x, draw_width = renderer.clip_h_span(state, vend - 1, 1, WIDTH)
    assert(visible_x and draw_width >= 1, "clip on the last visible frame must be drawn")
    assert(visible_x <= WIDTH - 1, string.format(
        "right-edge sliver must stay inside the track: x=%d track=%d",
        visible_x, WIDTH))
    print("  right-edge clip draws inside the track")
end

require("synthetic.helpers.blank_project").cleanup(db_path)
ui.cleanup()
print("✅ test_clip_draw_stability.lua passed")
