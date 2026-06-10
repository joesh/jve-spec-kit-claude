--- At far zoom-out (many frames per pixel), a clip's pixel width must be
-- constant as the viewport scrolls across it — no strobing. The time→pixel
-- map is a pure linear function of frame position and viewport width; width
-- = (clip_duration / viewport_duration) * widget_width is invariant under
-- scroll, so a clip that stays fully inside the viewport must draw with the
-- same pixel span on every scroll step.
--
-- Converted from tests/synthetic/lua/test_clip_flash_zoomed_out.lua
-- (which stubbed _G.timeline, the state module, and the view) — this
-- version drives real zoom/scroll commands and reads the real draw-command
-- queue.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")
local command_manager = require("core.command_manager")

print("=== test_clip_scroll_width_invariance ===")

env.boot()
local seq = env.fresh_sequence("Clip Scroll Width Invariance")
local tracks = env.tracks()
assert(tracks.V1, "no V1 track in fresh sequence")

-- Place a 500-frame clip at position 5000.
-- At viewport_duration ≈ 100 000 frames this is ~9-10 px wide in a typical
-- widget — comfortably above the sub-pixel cull threshold.
local CLIP_POSITION  = 5000
local CLIP_DURATION  = 500
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = CLIP_POSITION, duration = CLIP_DURATION },
})

-- Zoom far out so the clip is deeply sub-pixel: 100 000 frames shown at once.
local VIEWPORT_DURATION = 100000
local r = command_manager.execute("ZoomTimelineViewport", {
    duration_frames = VIEWPORT_DURATION,
    anchor_frame    = 0,
})
assert(r and r.success, "ZoomTimelineViewport failed: " .. tostring(r and r.error_message))
env.pump(100)

local widget = env.video_widget()

-- Find the clip body color by looking for a clip-colored rect right after
-- placing at CLIP_POSITION.  We use env.colors().clip_video; if it doesn't
-- exist fall back to any non-background rect that lands near x_of(CLIP_POSITION).
local CLIP_COLOR = assert(env.colors().clip_video,
    "timeline_state.colors.clip_video missing — needed to identify clip body rects")

-- Width of the clip at the current zoom.  Derived from the domain formula
-- (not from renderer source): width = (duration / viewport_duration) * widget_px.
-- At viewport_duration=100 000 and widget_width=1080 (typical), that is ~10.8 px.
-- We don't hard-code the widget width; we measure it through the binding.
local widget_px = env.widget_width(widget)
local expected_width_approx = (CLIP_DURATION / VIEWPORT_DURATION) * widget_px
-- A clip this wide must exist and be non-trivial (at least 1 px).
assert(expected_width_approx >= 1.0, string.format(
    "test precondition: clip width at this zoom (%.2f px) is below 1 px — "
    .. "the test cannot distinguish a cull from a strobe; increase widget width or "
    .. "decrease VIEWPORT_DURATION", expected_width_approx))

-- Scroll the viewport across the clip (viewport_start from 0 to CLIP_POSITION)
-- keeping the clip fully inside the visible window.  Assert:
--   (a) a clip-colored rect is drawn on EVERY step (no flash-off)
--   (b) the rect's width is constant across all steps (no strobe)
local first_width = nil
local mismatches  = {}
local missing     = {}

-- Advance by steps of 100 frames so the sweep is bounded but dense enough.
local STEP = 100
for vs = 0, CLIP_POSITION, STEP do
    local ok = command_manager.execute("ZoomTimelineViewport", {
        duration_frames = VIEWPORT_DURATION,
        anchor_frame    = vs,
    })
    assert(ok and ok.success, "ZoomTimelineViewport (scroll) failed at vs=" .. vs)
    env.pump(50)

    -- Clip should be visible whenever it overlaps the viewport.
    local vend = vs + VIEWPORT_DURATION
    local clip_end = CLIP_POSITION + CLIP_DURATION
    if vs < clip_end and CLIP_POSITION < vend then
        local clip_rects = env.rects(widget, CLIP_COLOR)
        if #clip_rects == 0 then
            missing[#missing + 1] = vs
        else
            -- Pick the widest matching rect as the clip body.
            local w = 0
            for _, rc in ipairs(clip_rects) do
                if rc.width > w then w = rc.width end
            end
            if not first_width then
                first_width = w
            elseif math.abs(w - first_width) > 1 then
                -- A real strobe is a full ±1 px or more; float rounding
                -- noise is much smaller than that.
                mismatches[#mismatches + 1] = { vs = vs, w = w }
            end
        end
    end
end

if #missing > 0 then
    local report = {}
    for i = 1, math.min(5, #missing) do
        report[i] = string.format("vs=%d: clip not drawn", missing[i])
    end
    error(string.format("%d scroll step(s) dropped a visible clip:\n  %s",
        #missing, table.concat(report, "\n  ")))
end

if #mismatches > 0 then
    local report = {}
    for i = 1, math.min(5, #mismatches) do
        report[i] = string.format("vs=%d: width=%d (expected %d)",
            mismatches[i].vs, mismatches[i].w, first_width)
    end
    error(string.format(
        "%d scroll step(s) drew a different clip width — strobing:\n  %s",
        #mismatches, table.concat(report, "\n  ")))
end

assert(first_width, "clip was never drawn in any scroll step — cannot verify width invariance")
print(string.format(
    "  clip width invariant (%.0f px) across %d scroll steps",
    first_width, math.floor(CLIP_POSITION / STEP) + 1))
print("✅ test_clip_scroll_width_invariance.lua passed")
