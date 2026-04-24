#!/usr/bin/env luajit

-- Test: scroll_axis_lock suppresses orthogonal deltas within a gesture.
--
-- Trackpad gestures arrive as a stream of (dx, dy) events. When the user's
-- motion is mostly along one axis, small orthogonal drift should not cause
-- accidental scrolling on the other axis. The axis-lock is per-gesture:
-- it resets after a quiet period (no wheel events for ~150ms).
--
-- Domain expectations:
--   1. When one axis clearly dominates, the orthogonal axis is zeroed.
--   2. When neither axis dominates (near-diagonal), both pass through.
--   3. The lock persists within a gesture even if a later event is diagonal.
--   4. After a quiet period, the next event can establish a new lock.

package.path = "src/lua/?.lua;src/lua/?/init.lua;tests/?.lua;" .. package.path

local axis_lock = require("ui.timeline.scroll_axis_lock")

-- =============================================================================
-- Test 1: strong horizontal → lock h, zero dy on subsequent diagonal events
-- =============================================================================
local s = axis_lock.new_state()
local dx, dy = axis_lock.apply(s, 10, 2, 1000)  -- ratio 5:1 → lock h
assert(dx == 10 and dy == 0,
    string.format("strong-h first event: expected (10, 0), got (%s, %s)",
        tostring(dx), tostring(dy)))

-- Within the gesture, a diagonal event's dy is suppressed
dx, dy = axis_lock.apply(s, 5, 4, 1050)  -- only 50ms later
assert(dx == 5 and dy == 0,
    string.format("locked-h diagonal: expected (5, 0), got (%s, %s)",
        tostring(dx), tostring(dy)))

-- Even a dy-dominant event within the gesture stays suppressed
dx, dy = axis_lock.apply(s, 1, 20, 1100)
assert(dx == 1 and dy == 0,
    "locked-h persists through dy-dominant events within the gesture")
print("  PASS: horizontal lock persists within gesture")

-- =============================================================================
-- Test 2: strong vertical → lock v, zero dx on subsequent events
-- =============================================================================
s = axis_lock.new_state()
dx, dy = axis_lock.apply(s, 2, 10, 2000)
assert(dx == 0 and dy == 10, "strong-v first event should lock v")

dx, dy = axis_lock.apply(s, 4, 5, 2050)
assert(dx == 0 and dy == 5, "locked-v should zero dx on diagonal")
print("  PASS: vertical lock persists within gesture")

-- =============================================================================
-- Test 3: near-diagonal first event → no lock, both pass through
-- =============================================================================
s = axis_lock.new_state()
dx, dy = axis_lock.apply(s, 10, 9, 3000)  -- ratio only 1.11
assert(dx == 10 and dy == 9,
    string.format("near-diagonal should not lock: got (%s, %s)", tostring(dx), tostring(dy)))
print("  PASS: near-diagonal gesture does not establish lock")

-- =============================================================================
-- Test 4: quiet period resets the gesture
-- =============================================================================
s = axis_lock.new_state()
axis_lock.apply(s, 10, 1, 4000)  -- lock h

-- Shortly after: still locked
dx, dy = axis_lock.apply(s, 1, 10, 4100)
assert(dx == 1 and dy == 0, "within-gesture event should still be h-locked")

-- After gap > SCROLL_GESTURE_GAP_MS (150): lock should reset
dx, dy = axis_lock.apply(s, 1, 10, 4300)  -- 200ms gap
assert(dx == 0 and dy == 10,
    string.format("after quiet period, new v-lock should apply: got (%s, %s)",
        tostring(dx), tostring(dy)))
print("  PASS: quiet period resets gesture and new axis can lock")

-- =============================================================================
-- Test 5: symmetric deltas (|dx| == |dy|) don't lock
-- =============================================================================
s = axis_lock.new_state()
dx, dy = axis_lock.apply(s, 10, 10, 5000)
assert(dx == 10 and dy == 10, "equal magnitudes should not lock")
print("  PASS: equal magnitudes do not lock")

-- =============================================================================
-- Test 6: zero deltas are passed through unchanged
-- =============================================================================
s = axis_lock.new_state()
dx, dy = axis_lock.apply(s, 0, 0, 6000)
assert(dx == 0 and dy == 0, "zero input → zero output")
print("  PASS: zero deltas pass through")

-- =============================================================================
-- Test 7: negative-direction strong horizontal locks horizontally
-- =============================================================================
s = axis_lock.new_state()
dx, dy = axis_lock.apply(s, -10, 2, 7000)
assert(dx == -10 and dy == 0, "negative dx should still establish h-lock")
print("  PASS: negative-direction events lock correctly")

print("\n✅ test_scroll_axis_lock.lua passed")
