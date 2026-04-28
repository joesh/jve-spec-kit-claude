#!/usr/bin/env luajit

-- Regression: trackpad scroll-direction axis lock got "stuck" — once a
-- gesture locked to vertical (or horizontal), it would not release across
-- subsequent gestures because wheel_timestamp_ms() fell back to
-- `os.clock() * 1000` (process CPU time) when the (never-registered)
-- `qt_elapsed_ms` Qt binding was missing. Between user gestures the app is
-- mostly idle, so CPU time barely advances; the GESTURE_GAP_MS=150 gap in
-- scroll_axis_lock therefore never tripped and the lock wedged for the rest
-- of the session.
--
-- Domain expectation: wheel_timestamp_ms() must reflect WALL-CLOCK time, so
-- a real-world quiet period between gestures releases the axis lock.

require("test_env")

-- Override the test_env stub (which itself uses os.clock) with a
-- programmable wall-clock fake. wheel_timestamp_ms must read through this.
local fake_wall_seconds = 1000.0
_G.qt_monotonic_s = function() return fake_wall_seconds end

local input = require("ui.timeline.view.timeline_view_input")
assert(type(input._wheel_timestamp_ms) == "function",
    "module must expose _wheel_timestamp_ms for regression coverage")

-- =============================================================================
-- Test 1: wheel_timestamp_ms reflects wall-clock advance
-- =============================================================================
local ts_before = input._wheel_timestamp_ms()
fake_wall_seconds = fake_wall_seconds + 0.250  -- advance wall time by 250ms
local ts_after = input._wheel_timestamp_ms()

local elapsed_ms = ts_after - ts_before
assert(elapsed_ms > 200,
    string.format(
        "wheel_timestamp_ms must reflect wall-clock advance; got %.3fms, expected >200ms",
        elapsed_ms))
print("  PASS: wheel_timestamp_ms reflects wall-clock advance")

-- =============================================================================
-- Test 2: end-to-end — vertical_allowed commitment from a previous gesture
-- does NOT leak into a fresh gesture across a wall-clock gap.
-- =============================================================================
-- Drives the same timestamp source through scroll_axis_lock.apply() that
-- timeline_view_input uses live. With the original CPU-clock fallback the
-- gap detector never tripped, so a previously-committed vertical gesture
-- would persist its commitment into the next horizontal gesture and
-- vertical scrolling would leak under a horizontal-only swipe.
local axis_lock = require("ui.timeline.scroll_axis_lock")
local s = axis_lock.new_state()

-- Drive a gesture clearly into vertical_allowed (sustained vertical intent)
for _ = 1, 7 do
    axis_lock.apply(s, 1, 8, input._wheel_timestamp_ms())
    fake_wall_seconds = fake_wall_seconds + 0.016  -- 16ms between events
end
do
    local _, dy = axis_lock.apply(s, 1, 8, input._wheel_timestamp_ms())
    assert(dy == 8, "sanity: previous gesture is in vertical_allowed mode")
end

-- Real-world pause between gestures: 250ms wall time, ~0 CPU time
fake_wall_seconds = fake_wall_seconds + 0.250

-- New gesture starts horizontal-dominant. The stale vertical_allowed
-- commitment from the prior gesture must reset on the wall-clock gap, so
-- this fresh gesture re-enters tentative and suppresses vertical jitter.
local dx, dy = axis_lock.apply(s, 10, 3, input._wheel_timestamp_ms())
assert(dx == 10 and dy == 0,
    string.format(
        "stale vertical_allowed must reset after wall-clock gap; got dx=%s dy=%s",
        tostring(dx), tostring(dy)))
print("  PASS: stale gesture commitment resets after wall-clock gap")

-- =============================================================================
-- Test 3: missing qt_monotonic_s binding fails loudly (NSF Half 1)
-- =============================================================================
-- The original bug shipped because wheel_timestamp_ms silently fell back
-- to os.clock() when qt_monotonic_s wasn't registered. The fix removed
-- the fallback and replaced it with an assert. Verify that assert fires
-- with an actionable message rather than a silent default.
local saved_qt_monotonic_s = _G.qt_monotonic_s
_G.qt_monotonic_s = nil
local ok, err = pcall(input._wheel_timestamp_ms)
_G.qt_monotonic_s = saved_qt_monotonic_s
assert(not ok, "wheel_timestamp_ms must assert when qt_monotonic_s is missing")
assert(type(err) == "string" and err:find("qt_monotonic_s", 1, true),
    "assert message must reference qt_monotonic_s for actionability; got " .. tostring(err))
print("  PASS: missing qt_monotonic_s binding fails loudly")

print("\n✅ test_wheel_timestamp_uses_wall_clock.lua passed")
