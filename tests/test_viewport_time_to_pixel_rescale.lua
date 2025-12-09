#!/usr/bin/env luajit

-- Regression: time_to_pixel must normalize Rational inputs to sequence FPS.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local Rational = require("core.rational")
local data = require("ui.timeline.state.timeline_state_data")
local viewport_state = require("ui.timeline.state.viewport_state")

-- Configure sequence rate and viewport
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.viewport_start_time = Rational.new(0, 24, 1)
data.state.viewport_duration = Rational.new(240, 24, 1) -- 10 seconds @24fps

local WIDTH = 1200

-- A clip timestamp expressed at 48fps should be rescaled to the 24fps timeline
local at_48fps = Rational.new(120, 48, 1) -- 120 frames @48fps = 2.5s
local at_24fps = Rational.new(60, 24, 1)  -- 60 frames @24fps  = 2.5s

local x_48 = viewport_state.time_to_pixel(at_48fps, WIDTH)
local x_24 = viewport_state.time_to_pixel(at_24fps, WIDTH)
assert(x_48 == 300, string.format("expected 300px for 2.5s@48fps, got %s", tostring(x_48)))
assert(x_24 == 300, string.format("expected 300px for 2.5s@24fps, got %s", tostring(x_24)))

-- Table payloads should hydrate and rescale as well
local x_table = viewport_state.time_to_pixel({ frames = 120, fps_numerator = 48, fps_denominator = 1 }, WIDTH)
assert(x_table == 300, string.format("expected 300px for table Rational, got %s", tostring(x_table)))

print("✅ viewport_state.time_to_pixel rescales inputs to sequence FPS")
