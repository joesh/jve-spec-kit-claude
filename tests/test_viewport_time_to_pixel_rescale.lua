#!/usr/bin/env luajit

-- Regression: time_to_pixel must accept integer frame inputs (no FPS rescaling).

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local test_env = require("test_env")
local viewport_state = require("ui.timeline.state.viewport_state")

-- Per-sequence view-state lives on the displayed tab's cache (H1).
test_env.install_displayed_tab_stub({
    sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 },
    viewport_start_time = 0,
    viewport_duration = 240, -- 10 seconds @24fps
})

local WIDTH = 1200
-- 240 frames across 1200px => 5px/frame

-- Integer frame inputs map directly to pixels
local x_60 = viewport_state.time_to_pixel(60, WIDTH)
local x_120 = viewport_state.time_to_pixel(120, WIDTH)
assert(x_60 == 300, string.format("expected 300px for 60 frames, got %s", tostring(x_60)))
assert(x_120 == 600, string.format("expected 600px for 120 frames, got %s", tostring(x_120)))

-- Table payloads are not supported (only integer frames)
local ok = pcall(function()
    return viewport_state.time_to_pixel({ frames = 120 }, WIDTH)
end)
assert(not ok, "table inputs must be rejected - only integer frames accepted")

print("✅ viewport_state.time_to_pixel handles integer frame inputs")
