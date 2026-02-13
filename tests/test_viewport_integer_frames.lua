#!/usr/bin/env luajit

-- Regression: viewport state setters must reject non-integer frame values.
-- Bug: scroll/zoom handlers computed fractional frames (e.g., 298.828125)
-- which flowed to DB and were rejected by Rational.new on read-back.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local data = require("ui.timeline.state.timeline_state_data")
local viewport_state = require("ui.timeline.state.viewport_state")

-- Configure valid initial state
data.state.sequence_frame_rate = { fps_numerator = 24, fps_denominator = 1 }
data.state.viewport_start_time = 0
data.state.viewport_duration = 300
data.state.playhead_position = 0

-- =============================================================================
-- Test: set_viewport_start_time rejects non-integer
-- =============================================================================
local ok, err = pcall(viewport_state.set_viewport_start_time, 298.5)
assert(not ok, "set_viewport_start_time(298.5) should assert")
assert(tostring(err):find("integer"), string.format(
    "Error should mention 'integer', got: %s", tostring(err)))
print("  PASS: set_viewport_start_time rejects 298.5")

-- Test: set_viewport_start_time accepts integer
data.state.viewport_start_time = 0  -- reset
ok = pcall(viewport_state.set_viewport_start_time, 100)
assert(ok, "set_viewport_start_time(100) should succeed")
print("  PASS: set_viewport_start_time accepts integer 100")

-- Test: set_viewport_start_time accepts 0
ok = pcall(viewport_state.set_viewport_start_time, 0)
assert(ok, "set_viewport_start_time(0) should succeed")
print("  PASS: set_viewport_start_time accepts 0")

-- =============================================================================
-- Test: set_viewport_duration rejects non-integer
-- =============================================================================
data.state.viewport_duration = 300  -- reset
ok, err = pcall(viewport_state.set_viewport_duration, 300.25)
assert(not ok, "set_viewport_duration(300.25) should assert")
assert(tostring(err):find("integer"), string.format(
    "Error should mention 'integer', got: %s", tostring(err)))
print("  PASS: set_viewport_duration rejects 300.25")

-- Test: set_viewport_duration accepts integer
ok = pcall(viewport_state.set_viewport_duration, 480)
assert(ok, "set_viewport_duration(480) should succeed")
print("  PASS: set_viewport_duration accepts integer 480")

-- =============================================================================
-- Test: set_playhead_position rejects non-integer
-- =============================================================================
data.state.playhead_position = 0  -- reset
ok, err = pcall(viewport_state.set_playhead_position, 50.7)
assert(not ok, "set_playhead_position(50.7) should assert")
assert(tostring(err):find("integer"), string.format(
    "Error should mention 'integer', got: %s", tostring(err)))
print("  PASS: set_playhead_position rejects 50.7")

-- Test: set_playhead_position accepts integer
ok = pcall(viewport_state.set_playhead_position, 50)
assert(ok, "set_playhead_position(50) should succeed")
print("  PASS: set_playhead_position accepts integer 50")

-- =============================================================================
-- Test: clamp_viewport_start rejects non-integer (tested via set_viewport_start_time)
-- =============================================================================
data.state.viewport_duration = 300
ok = pcall(viewport_state.set_viewport_start_time, 10.999)
assert(not ok, "clamp_viewport_start should reject 10.999")
print("  PASS: clamp_viewport_start rejects non-integer")

print("✅ test_viewport_integer_frames.lua passed")
