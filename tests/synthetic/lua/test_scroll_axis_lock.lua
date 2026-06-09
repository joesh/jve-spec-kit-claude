#!/usr/bin/env luajit

-- Test: scroll_axis_lock applies asymmetric vertical-suppression on the
-- timeline. Horizontal motion is always allowed through; vertical motion
-- is suppressed by default at gesture start and only released when the
-- user demonstrates sustained vertical intent.
--
-- Domain expectations:
--   1. Horizontal is NEVER suppressed — every dx passes through unchanged.
--   2. A horizontal-dominant gesture pins vertical at zero for the entire
--      gesture, including end-of-gesture vertical drift (the "kicked off
--      the track at the end of a horizontal swipe" failure mode).
--   3. Vertical is suppressed during the opening jitter of any gesture,
--      so a clean horizontal swipe that starts with a brief diagonal
--      doesn't move the tracks vertically.
--   4. Vertical is released only when cumulative |dy| both clearly
--      dominates and crosses an intent threshold — sustained vertical
--      motion, not a single tall event in the noise.
--   5. A quiet period resets the gesture and its classification.

require("test_env")

local axis_lock = require("ui.timeline.scroll_axis_lock")

-- =============================================================================
-- Test 1: horizontal is always allowed through, even on the first event
-- =============================================================================
local _  -- discard slot for unused dx returns
local s = axis_lock.new_state()
local dx, dy = axis_lock.apply(s, 10, 2, 1000)
assert(dx == 10 and dy == 0,
    string.format("horizontal-dominant first event: expected (10, 0), got (%s, %s)",
        tostring(dx), tostring(dy)))
print("  PASS: horizontal passes through, vertical jitter suppressed at start")

-- =============================================================================
-- Test 2: end-of-gesture vertical drift after a horizontal-dominant sweep
-- stays suppressed (the user-reported regression)
-- =============================================================================
s = axis_lock.new_state()
-- A clean horizontal sweep — many events well past HORIZONTAL_COMMIT_PX
for i = 0, 4 do
    axis_lock.apply(s, 10, 1, 2000 + i * 16)
end
-- Now the user lets up and a final wheel event slips in with vertical drift
_, dy = axis_lock.apply(s, 1, 8, 2000 + 5 * 16)
assert(dy == 0,
    string.format("late vertical drift on a horizontal gesture must stay suppressed; got dy=%s",
        tostring(dy)))
print("  PASS: horizontal-committed gesture suppresses late vertical drift")

-- =============================================================================
-- Test 3: sustained vertical intent releases vertical (and horizontal too)
-- =============================================================================
s = axis_lock.new_state()
-- Several vertical-dominant events accumulating well past the intent threshold
for i = 0, 6 do
    axis_lock.apply(s, 1, 8, 3000 + i * 16)
end
dx, dy = axis_lock.apply(s, 2, 8, 3000 + 7 * 16)
assert(dy == 8,
    string.format("sustained vertical intent must release dy; got dy=%s",
        tostring(dy)))
assert(dx == 2, "horizontal still passes through after vertical commit")
print("  PASS: sustained vertical intent releases vertical motion")

-- =============================================================================
-- Test 4: opening diagonal jitter does not commit the gesture vertically
-- =============================================================================
s = axis_lock.new_state()
-- A vertical-leaning first event of small magnitude (typical opening jitter)
_, dy = axis_lock.apply(s, 2, 4, 4000)
assert(dy == 0,
    "small vertical-dominant first event is jitter, must be suppressed")
-- Followed by a long horizontal sweep — gesture should commit horizontal_only
for i = 1, 4 do
    axis_lock.apply(s, 10, 0, 4000 + i * 16)
end
-- Even a later vertical-dominant event must stay suppressed (committed h)
_, dy = axis_lock.apply(s, 0, 10, 4000 + 5 * 16)
assert(dy == 0,
    string.format("opening jitter must not strand the gesture in vertical_allowed; got dy=%s",
        tostring(dy)))
print("  PASS: opening jitter does not lock the gesture into vertical mode")

-- =============================================================================
-- Test 5: quiet period resets the gesture so a fresh classification can occur
-- =============================================================================
s = axis_lock.new_state()
-- Commit to horizontal_only via a sustained horizontal sweep
for i = 0, 4 do
    axis_lock.apply(s, 10, 0, 5000 + i * 16)
end
-- Confirm vertical still suppressed mid-gesture
_, dy = axis_lock.apply(s, 0, 10, 5000 + 5 * 16)
assert(dy == 0, "still horizontal_only mid-gesture")

-- After a quiet period > GESTURE_GAP_MS (150), a fresh sustained vertical
-- gesture should be allowed.
local fresh_t0 = 5000 + 5 * 16 + 300
for i = 0, 6 do
    axis_lock.apply(s, 0, 8, fresh_t0 + i * 16)
end
_, dy = axis_lock.apply(s, 0, 8, fresh_t0 + 7 * 16)
assert(dy == 8,
    string.format("after quiet period, new vertical gesture should pass; got dy=%s",
        tostring(dy)))
print("  PASS: quiet period resets gesture and new vertical gesture passes")

-- =============================================================================
-- Test 6: zero deltas pass through unchanged
-- =============================================================================
s = axis_lock.new_state()
dx, dy = axis_lock.apply(s, 0, 0, 6000)
assert(dx == 0 and dy == 0, "zero input → zero output")
print("  PASS: zero deltas pass through")

-- =============================================================================
-- Test 7: negative-direction horizontal still passes through
-- =============================================================================
s = axis_lock.new_state()
dx, dy = axis_lock.apply(s, -10, 2, 7000)
assert(dx == -10 and dy == 0,
    "negative dx must pass through; vertical still suppressed at start")
print("  PASS: negative horizontal passes through")

-- =============================================================================
-- Test 8: vertical-leaning opening jitter that crosses the vertical-intent
-- threshold BEFORE horizontal kicks in — once horizontal accumulates past
-- the commit threshold, vertical must be reclaimed (no leak through the
-- rest of the gesture).
-- =============================================================================
-- This is the user-reported regression: a long horizontal scroll with
-- early vertical drift would commit to vertical_allowed (cum_dy >= 30
-- before cum_dx >= 20), and then late horizontal events would still allow
-- vertical drift through. The horizontal ratchet must override.
s = axis_lock.new_state()
-- Vertical-leaning opening: cum_dy crosses 30 while cum_dx stays small
for i = 0, 4 do
    axis_lock.apply(s, 1, 8, 8000 + i * 16)  -- 5 events: cum_dx=5, cum_dy=40
end
-- Verify the pre-condition: vertical was momentarily allowed.
_, dy = axis_lock.apply(s, 1, 8, 8000 + 5 * 16)
assert(dy == 8, "sanity: gesture entered vertical_allowed during opening")

-- User now sweeps horizontally hard; cum_dx crosses 20 → ratchet horizontal_only
for i = 6, 10 do
    axis_lock.apply(s, 10, 1, 8000 + i * 16)
end
-- A subsequent vertical-leaning event must NOT bleed dy through anymore
_, dy = axis_lock.apply(s, 1, 9, 8000 + 11 * 16)
assert(dy == 0,
    string.format(
        "horizontal ratchet must reclaim a previously vertical_allowed gesture; got dy=%s",
        tostring(dy)))
print("  PASS: horizontal ratchet reclaims gesture from vertical_allowed")

-- =============================================================================
-- Test 9: long horizontal sweep with continuous mild vertical drift never
-- bleeds vertical through, no matter how far the user goes.
-- =============================================================================
-- The user's report — "I can be scrolling horiz and vert can still break
-- through if I go far enough" — covers the case where cum_dy quietly grows
-- alongside cum_dx for a long time. The horizontal ratchet pins
-- horizontal_only the moment cum_dx >= HORIZONTAL_COMMIT_PX, and that
-- decision is stable for the rest of the gesture.
s = axis_lock.new_state()
local last_dy_emitted = nil
for i = 0, 99 do
    local _, emitted_dy = axis_lock.apply(s, 8, 3, 9000 + i * 16)
    last_dy_emitted = emitted_dy
    -- After cum_dx crosses 20 (event 3), every subsequent emitted dy must be 0.
    if i >= 3 then
        assert(emitted_dy == 0,
            string.format(
                "long horizontal swipe leaked vertical at event %d; got dy=%s",
                i, tostring(emitted_dy)))
    end
end
assert(last_dy_emitted == 0,
    "long horizontal swipe must not leak vertical even after many events")
print("  PASS: long horizontal sweep with steady vertical drift never leaks dy")

print("\n✅ test_scroll_axis_lock.lua passed")
