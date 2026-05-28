#!/usr/bin/env luajit
--- Regression test for sub-frame trackpad-wheel motion at high zoom.
---
--- Pre-fix behavior (TSO 2026-04-28 10:37:24): when each wheel event
--- contributes < 1 frame of viewport motion, `math.floor(prev + delta)`
--- discards the fractional component every event. The viewport never
--- advances in the dominant scroll direction (RIGHT, because floor rounds
--- toward −∞), and the perf-log fills with `desired_delta=0 notified=false`
--- entries that still pay an O(N) clip scan inside the clamp.
---
--- Domain rules pinned here:
---
---   * Multiple sub-frame events accumulate to whole-frame viewport motion.
---     Eight events of +0.16 frames must net to a +1-frame advance somewhere
---     inside the burst — not zero motion forever.
---
---   * The accumulation works in BOTH directions; right (positive) doesn't
---     get penalized by floor's rounding. Eight events of −0.16 net to −1.
---
---   * Direction reversal cancels accumulated fraction. A right-leaning
---     +0.5-frame partial followed by left-leaning −0.5 nets to no motion;
---     the residue from the right swipe doesn't ghost-jump into the left.
---
---   * A pause longer than SCROLL_GESTURE_GAP_MS resets the accumulator —
---     a fresh gesture cannot inherit the prior gesture's fraction.
require("test_env")
-- H1 (#28): command_manager captures playhead from the displayed tab's
-- cache. Tests that exercise command_manager without a real timeline
-- install a default stub (playhead=0, viewport=(0,300), fps=30/1) so
-- capture succeeds. Pre-H1 the singleton mirror provided these defaults
-- implicitly; post-H1 every test states its intent explicitly.
require('test_env').install_displayed_tab_stub()

local input = require("ui.timeline.view.timeline_view_input")
local ui_constants = require("core.ui_constants")
local GAP_MS = ui_constants.TIMELINE.SCROLL_GESTURE_GAP_MS

-- Mock view: viewport 122 frames over a 1556-px wide widget — the exact
-- zoom from the TSO repro (≈12.7 px per frame; sub-pixel wheel deltas
-- correspond to fractional-frame motion).
local current_start = 145127
local set_calls = {}
local function record_set(new_start)
    table.insert(set_calls, new_start)
    current_start = new_start
end
local mock_state = {
    get_viewport_duration = function() return 122 end,
    get_viewport_start_time = function() return current_start end,
    set_viewport_start_time = record_set,
    flush_pending_notify = function() end,
}
local view = { state = mock_state, widget = "mock_widget" }
_G.timeline = { get_dimensions = function() return 1556 end }

-- Handler dispatches through command_manager → ScrollTimelineViewport →
-- ui.timeline.timeline_state. Stub the module-level setter so the
-- per-call observations land in set_calls regardless of dispatch path.
local real_ts = require("ui.timeline.timeline_state")
real_ts.get_viewport_start_time = function() return current_start end
real_ts.set_viewport_start_time = record_set

local function reset(view_obj)
    view_obj._scroll_axis_state = nil
    set_calls = {}
end

-- A wheel-event helper that lets the test control the wall clock.
local fake_t_s = 1000
_G.qt_monotonic_s = function() return fake_t_s end
local function wheel(dx, dy, dt_ms)
    fake_t_s = fake_t_s + (dt_ms or 16) / 1000
    input.handle_wheel(view, dx, dy, {})
end

-- =============================================================================
-- Test 1: sub-frame RIGHT motion accumulates and eventually advances
-- =============================================================================
-- Each event contributes (-2 / 1556) * 122 ≈ -0.157 frames per event.
-- After eight events, accumulated motion is ≈ -1.25 frames — the viewport
-- must have moved by an integer number of frames in the leftward direction.
-- (`-2` here is "right-going content" — wheel pushes content right, which
-- is a NEGATIVE viewport_start delta. The pre-fix bug shows up identically
-- for the symmetric case in Test 2.)
reset(view)
current_start = 145127
for _ = 1, 8 do
    wheel(2, 0, 16)
end
local total_delta = (set_calls[#set_calls] or current_start) - 145127
assert(total_delta < 0, string.format(
    "eight sub-frame +pixel-dx events must accumulate into observable "
    .. "leftward viewport motion (delta < 0); got %d", total_delta))

-- =============================================================================
-- Test 2: sub-frame LEFT/RIGHT each direction works (the asymmetry bug)
-- =============================================================================
-- The pre-fix bug: math.floor of (prev + 0.157) == prev (truncates fraction
-- toward -inf). Scrolling RIGHT-going-content (negative dx pushing content
-- left, positive dx pushing right) at high zoom stalled in one direction
-- but not the other. Both directions must accumulate.
reset(view)
current_start = 145127
for _ = 1, 8 do
    wheel(-2, 0, 16)
end
local right_delta = current_start - 145127
assert(right_delta > 0, string.format(
    "eight sub-frame -pixel-dx events must accumulate into observable "
    .. "rightward viewport motion (delta > 0) — pre-fix bug stalled this "
    .. "direction at floor's rounding; got %d", right_delta))

-- =============================================================================
-- Test 3: direction reversal cancels accumulated fraction
-- =============================================================================
-- A user swipes right with sub-frame motion, then immediately reverses.
-- The right-swipe's residual must NOT ghost-jump into the left-swipe.
reset(view)
current_start = 145127
-- Build up a partial-frame fraction without committing a whole frame
-- (one event of ~0.157 frames < 1).
wheel(-2, 0, 16)
local after_partial_right = current_start
-- Symmetric reversal: equal-magnitude opposite event in the same gesture.
wheel(2, 0, 16)
local after_reversal = current_start
local cancellation = after_reversal - after_partial_right
assert(cancellation == 0, string.format(
    "an immediate direction-reversal event of equal magnitude must cancel "
    .. "the prior event's fractional accumulation, not commit it; got "
    .. "post-reversal delta=%d (after_partial_right=%d, after_reversal=%d)",
    cancellation, after_partial_right, after_reversal))

-- =============================================================================
-- Test 4: gesture-gap pause discards accumulated fraction
-- =============================================================================
-- The user-visible promise: a single tiny scroll-then-pause-then-tiny-scroll
-- must NOT make the viewport jump on the post-pause event from residue the
-- pre-pause gesture left behind. Concretely: pump enough sub-frame events
-- in gesture A to accumulate close-to-but-under one whole frame; pause for
-- longer than GESTURE_GAP_MS; pump one more sub-frame event. Without a
-- gesture-boundary reset of the fraction, the post-pause event tips the
-- inherited residue across the integer boundary and produces a ghost-jump.
-- With reset, the post-pause event starts fresh and commits no motion.
reset(view)
current_start = 145127
fake_t_s = 1000

for _ = 1, 6 do
    wheel(-2, 0, 16)
end
local after_a = current_start
assert(after_a == 145127,
    "test setup: gesture A's sub-frame events must not yet have crossed a whole-frame boundary")

fake_t_s = fake_t_s + (GAP_MS + 100) / 1000
input.handle_wheel(view, -2, 0, {})
assert(current_start == after_a, string.format(
    "first event of a fresh gesture (after GAP_MS pause) must not commit a "
    .. "whole frame from the prior gesture's residual fraction; expected "
    .. "viewport_start unchanged at %d, got %d", after_a, current_start))

print("\n✅ test_wheel_subframe_accumulator.lua passed")
