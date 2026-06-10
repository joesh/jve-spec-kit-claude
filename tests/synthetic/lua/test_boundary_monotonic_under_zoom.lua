#!/usr/bin/env luajit

-- Regression: while zooming steadily in one direction, the drawn position
-- of a fixed timeline boundary (clip edge, gap edge) must move in one
-- direction only — never wobble back and forth.
--
-- Bug symptom (Joe, 2026-06-09): during a continuous zoom drag the lines
-- between clips jiggle. Each boundary's pixel position wobbled ±1 px
-- non-monotonically as pixels-per-frame swept, every boundary at a
-- different phase, so the whole timeline shimmered.
--
-- Domain assertion: with the viewport's left edge anchored, zooming OUT
-- (duration increasing) moves every boundary right of the anchor toward
-- it — its pixel position is non-increasing across the sweep. Mirrored
-- check zooming IN: non-decreasing.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local test_env = require("test_env")
local viewport_state = require("ui.timeline.state.viewport_state")

local VIEWPORT_WIDTH = 1920

-- Left edge anchored at a non-round frame so the mapping's treatment of
-- the viewport origin is actually exercised (vs = 0 hides it).
local VIEWPORT_START = 4321

-- Boundaries at varied distances from the anchor, odd offsets.
local BOUNDARIES = { 4567, 5500, 9013, 30011, 99991 }

local cache = test_env.install_displayed_tab_stub({
    sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 },
    viewport_start_time = VIEWPORT_START,
    viewport_duration = 100000,
})

local function sweep(from_duration, to_duration, step, direction_name, must_not)
    local prev = {}
    local violations = {}
    local d = from_duration
    while (step > 0 and d <= to_duration) or (step < 0 and d >= to_duration) do
        cache.viewport_duration = d
        for _, b in ipairs(BOUNDARIES) do
            local px = viewport_state.time_to_pixel(b, VIEWPORT_WIDTH)
            local p = prev[b]
            if p ~= nil and must_not(px, p) then
                violations[#violations + 1] = string.format(
                    "boundary %d moved %+.3f px against the %s sweep at duration=%d",
                    b, px - p, direction_name, d)
            end
            prev[b] = px
        end
        d = d + step
    end
    return violations
end

-- Zoom OUT: every boundary drifts left (non-increasing px).
local out_violations = sweep(100000, 110000, 7, "zoom-out",
    function(px, p) return px > p end)
-- Zoom IN: every boundary drifts right (non-decreasing px).
local in_violations = sweep(110000, 100000, -7, "zoom-in",
    function(px, p) return px < p end)

local all = {}
for _, v in ipairs(out_violations) do all[#all + 1] = v end
for _, v in ipairs(in_violations) do all[#all + 1] = v end

if #all > 0 then
    for i = 1, math.min(8, #all) do print("  " .. all[i]) end
    error(string.format(
        "%d boundary-position reversals during steady zoom — lines jiggle",
        #all))
end

print("  PASS: no boundary-position reversals across both zoom sweeps")
print("\n✅ test_boundary_monotonic_under_zoom.lua passed")
