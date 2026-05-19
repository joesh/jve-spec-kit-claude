#!/usr/bin/env luajit
--- Regression test for the macOS momentum-tail bridging bug in the
--- scroll axis lock.
---
--- Repro (user report 2026-05-19): user makes a horizontal trackpad
--- sweep on the timeline. They lift their fingers. macOS keeps
--- emitting `ScrollMomentum` wheel events with small decaying dx for
--- 1-2 seconds. Each momentum event updates `state.last_ts` (no
--- gesture-gap trips) and accumulates into `cum_dx` (so the lock
--- stays `horizontal_only`). When the user puts fingers back on the
--- trackpad and tries a fresh VERTICAL scroll, the gesture is still
--- in horizontal_only mode and vertical motion is suppressed for as
--- long as the OS-level momentum tail bridges the timestamp gap.
---
--- Inferring "fingers lifted" from timestamps alone is impossible
--- when momentum events fire at ~60Hz. Qt's QWheelEvent::phase()
--- reports `ScrollBegin` on every fresh fingers-down touch, and that
--- IS the authoritative gesture boundary. This test pins:
---
---   * A fresh-touch wheel event (phase = "begin") must HARD RESET
---     the axis lock, regardless of how recently the prior gesture
---     accumulated horizontal motion. Otherwise a momentum-bridged
---     new gesture inherits the prior lock and the user's vertical
---     intent is silently dropped.
---
---   * Momentum events (phase = "momentum") that arrive AFTER the
---     user committed horizontally must NOT prevent a subsequent
---     ScrollBegin from reaching vertical_allowed.
require("test_env")

local scroll_axis_lock = require("ui.timeline.scroll_axis_lock")
local ui_constants = require("core.ui_constants")
local HORIZONTAL_COMMIT_PX = ui_constants.TIMELINE.SCROLL_HORIZONTAL_COMMIT_PX
local VERTICAL_INTENT_PX = ui_constants.TIMELINE.SCROLL_VERTICAL_INTENT_PX

print("=== test_wheel_phase_resets_axis_lock.lua ===")

-- =============================================================================
-- Test 1: horizontal commit + momentum tail + phase=begin vertical = unlocked
-- =============================================================================
-- Simulates the exact failure mode: user sweeps horizontally and crosses
-- the commit threshold, lifts fingers, the OS streams momentum events at
-- ~60Hz for a while, then the user puts fingers back down for a fresh
-- vertical gesture. With phase routing in place, the fresh ScrollBegin
-- MUST hard-reset the gesture so vertical is allowed.
local state = scroll_axis_lock.new_state()
local t = 1000

-- Initial horizontal sweep: phase="begin" then several "update" events
-- that cross HORIZONTAL_COMMIT_PX so the gesture latches horizontal_only.
scroll_axis_lock.apply(state, HORIZONTAL_COMMIT_PX + 5, 0, t, "begin")
t = t + 16
for _ = 1, 4 do
    scroll_axis_lock.apply(state, 8, 0, t, "update")
    t = t + 16
end
assert(state.mode == "horizontal_only",
    "precondition: sweep across the horizontal commit threshold must "
    .. "latch horizontal_only; got " .. tostring(state.mode))

-- Momentum tail: small decaying dx, no significant dy, no time gap.
-- Pre-fix this kept the lock alive indefinitely.
for _ = 1, 30 do
    scroll_axis_lock.apply(state, 1.5, 0.1, t, "momentum")
    t = t + 16
end

-- User's fingers go back down for a vertical gesture. phase="begin"
-- is the authoritative signal that a new gesture has started; the
-- lock MUST reset BEFORE the dy of this very event is filtered, so
-- the first event of the fresh gesture already gets vertical motion
-- through (vertical events typically open with a large dy and that
-- intent must not be silently dropped).
local _, dy_out = scroll_axis_lock.apply(state, 0, VERTICAL_INTENT_PX + 10, t, "begin")
assert(dy_out ~= 0, string.format(
    "fresh ScrollBegin after a momentum tail must reset the axis lock "
    .. "so vertical intent passes through; got dy_out=%s, mode=%s",
    tostring(dy_out), tostring(state.mode)))
print("  ✓ ScrollBegin after horizontal+momentum tail unlocks vertical")

-- =============================================================================
-- Test 2: phase=begin resets cumulative tallies, not just mode
-- =============================================================================
-- If the reset cleared `mode` but left cum_dx near the threshold, the
-- next small horizontal drift would re-latch horizontal_only on the
-- second event of the new gesture — silently kicking us back into the
-- old behavior. Verify reset is total.
state = scroll_axis_lock.new_state()
t = 2000
scroll_axis_lock.apply(state, HORIZONTAL_COMMIT_PX + 5, 0, t, "begin")
t = t + 16
scroll_axis_lock.apply(state, 0, 0, t, "begin")
assert(state.cum_dx == 0 and state.cum_dy == 0 and state.mode == "tentative",
    string.format("fresh ScrollBegin must clear cum_dx/cum_dy/mode "
        .. "completely; got cum_dx=%s cum_dy=%s mode=%s",
        tostring(state.cum_dx), tostring(state.cum_dy), tostring(state.mode)))
print("  ✓ ScrollBegin clears cumulative tallies and resets mode")

-- =============================================================================
-- Test 3: momentum events don't lock a gesture that hasn't committed
-- =============================================================================
-- A subtler variant: brief tentative horizontal motion (below the commit
-- threshold) + momentum tail. If momentum accumulation crosses the
-- threshold post-hoc, the user's NEXT real gesture (phase=begin) must
-- still start fresh.
state = scroll_axis_lock.new_state()
t = 3000
-- Brief tentative horizontal — well below commit
scroll_axis_lock.apply(state, 2, 0, t, "begin")
t = t + 16
-- Momentum carries it past the threshold
for _ = 1, 20 do
    scroll_axis_lock.apply(state, 2, 0, t, "momentum")
    t = t + 16
end
-- New fingers-down with vertical intent
local _, dy_out2 = scroll_axis_lock.apply(state, 0, VERTICAL_INTENT_PX + 10, t, "begin")
assert(dy_out2 ~= 0, string.format(
    "ScrollBegin must override any horizontal_only that momentum events "
    .. "alone induced; got dy_out=%s mode=%s",
    tostring(dy_out2), tostring(state.mode)))
print("  ✓ ScrollBegin overrides momentum-induced horizontal_only")

print("\n✅ test_wheel_phase_resets_axis_lock.lua passed")
