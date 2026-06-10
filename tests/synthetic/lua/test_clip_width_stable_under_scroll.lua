#!/usr/bin/env luajit

-- Regression: at sub-pixel zoom (pixels_per_frame << 1), a clip of fixed
-- frame extent must draw the same pixel width regardless of viewport scroll.
--
-- Bug symptom: when zoomed out, clips strobe/breathe by ±1 px as the
-- timeline scrolls, because time_to_pixel quantized to integer pixels
-- with viewport_start folded inside the floor — the fractional parts of
-- (clip_start - vs) * ppf and (clip_end - vs) * ppf shifted
-- independently with vs.
--
-- Domain assertion: pixel width of a clip with fixed frame bounds is a
-- function of (clip_start, clip_end, ppf) only. Translating the viewport
-- in whole frames must not change it. time_to_pixel is an exact float
-- map (quantization happens at paint time, antialiased), so "must not
-- change" means within float-arithmetic noise — far below a hundredth
-- of a pixel — not bit-exact equality.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local test_env = require("test_env")
local viewport_state = require("ui.timeline.state.viewport_state")

-- Deep zoom-out: 1920 px viewport, 100000 frames duration → ppf ≈ 0.0192
local VIEWPORT_WIDTH = 1920
local VIEWPORT_DURATION = 100000

-- A clip that spans enough frames to have a meaningful pixel width
-- (~9-10 px at this zoom level). Width must be invariant under scroll.
local CLIP_START = 5000
local CLIP_END = 5500

-- Per-sequence view-state lives on the displayed tab's cache (H1).
local cache = test_env.install_displayed_tab_stub({
    sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 },
    viewport_start_time = 0,
    viewport_duration = VIEWPORT_DURATION,
})

local widths = {}
local first_width
for vs = 4500, 5500 do
    cache.viewport_start_time = vs
    local x = viewport_state.time_to_pixel(CLIP_START, VIEWPORT_WIDTH)
    local end_px = viewport_state.time_to_pixel(CLIP_END, VIEWPORT_WIDTH)
    local w = end_px - x
    table.insert(widths, { vs = vs, w = w })
    if not first_width then first_width = w end
end

-- All recorded widths must equal first_width (within float noise; a real
-- strobe is a full ±1 px, five orders of magnitude above this tolerance).
local EPSILON = 1e-6
local mismatches = {}
for _, rec in ipairs(widths) do
    if math.abs(rec.w - first_width) > EPSILON then
        table.insert(mismatches, rec)
    end
end

if #mismatches > 0 then
    print(string.format("first_width = %.9f", first_width))
    for i = 1, math.min(8, #mismatches) do
        local rec = mismatches[i]
        print(string.format("  vs=%d  width=%.9f  (expected %.9f)", rec.vs, rec.w, first_width))
    end
    error(string.format(
        "%d/%d scroll steps produced a different clip width — strobing regression",
        #mismatches, #widths))
end

print(string.format("  PASS: all %d scroll steps held width=%.3f", #widths, first_width))
print("\n✅ test_clip_width_stable_under_scroll.lua passed")
