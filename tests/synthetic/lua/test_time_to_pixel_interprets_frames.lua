#!/usr/bin/env luajit

-- Regression: viewport_state.time_to_pixel must treat numeric inputs as frame counts, not milliseconds.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local test_env = require("test_env")

local viewport_state = require("ui.timeline.state.viewport_state")

-- Per-sequence view-state lives on the displayed tab's cache (H1).
test_env.install_displayed_tab_stub({
    sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 },
    viewport_start_time = 0,
    viewport_duration = 240, -- 10s window
})

local width = 1200

-- 24 fps, 10s window => 240 frames across 1200px => 5px/frame.
local function expect_px(frames)
    return frames * 5
end

-- Integer numerics are treated as frame counts.
assert(viewport_state.time_to_pixel(0, width) == expect_px(0))
assert(viewport_state.time_to_pixel(24, width) == expect_px(24))
assert(viewport_state.time_to_pixel(120, width) == expect_px(120))

-- Fractional numerics should throw.
local ok = pcall(function() return viewport_state.time_to_pixel(12.5, width) end)
assert(not ok, "fractional numerics must be rejected")

-- Table inputs are no longer supported - everything is integer frames
local ok2 = pcall(function() return viewport_state.time_to_pixel({frames = 120}, width) end)
assert(not ok2, "table inputs must be rejected - only integer frames accepted")

print("✅ viewport_state.time_to_pixel interprets integers as frames and rejects non-integers")
