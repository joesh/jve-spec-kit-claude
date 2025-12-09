#!/usr/bin/env luajit

-- Regression: viewport_state.time_to_pixel must treat numeric inputs as frame counts, not milliseconds.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

require("test_env")

local Rational = require("core.rational")
local data = require("ui.timeline.state.timeline_state_data")
local viewport_state = require("ui.timeline.state.viewport_state")

data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.viewport_start_time = Rational.new(0, 24, 1)
data.state.viewport_duration = Rational.new(240, 24, 1) -- 10s window

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
local ok, err = pcall(function() return viewport_state.time_to_pixel(12.5, width) end)
assert(not ok, "fractional numerics must be rejected")

-- Rational inputs still work for frame-precise positions.
assert(viewport_state.time_to_pixel(Rational.new(120, 24, 1), width) == expect_px(120))

print("✅ viewport_state.time_to_pixel interprets integers as frames and rejects fractional numerics")
