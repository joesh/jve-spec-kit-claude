--- scroll_axis_lock.lua — asymmetric per-gesture vertical-suppression filter
-- for trackpad wheel events on the timeline.
--
-- Horizontal motion is the primary use of the timeline view; vertical drift
-- on a horizontal swipe is the truly annoying failure mode (the timeline
-- jumps off the track the user was looking at). Conversely, suppressing
-- horizontal is never desirable on this widget — there is no other
-- horizontal navigation gesture worth protecting.
--
-- Therefore this module is asymmetric and aggressively favors horizontal:
--   • Horizontal delta (dx) is ALWAYS passed through unchanged.
--   • Vertical delta (dy) is suppressed by default at the start of every
--     gesture (eats opening jitter).
--   • Vertical is released ("vertical_allowed") only when cumulative |dy|
--     crosses SCROLL_VERTICAL_INTENT_PX BEFORE cumulative |dx| has crossed
--     SCROLL_HORIZONTAL_COMMIT_PX — i.e., the gesture is essentially pure
--     vertical.
--   • Once cumulative |dx| crosses SCROLL_HORIZONTAL_COMMIT_PX, the gesture
--     ratchets to "horizontal_only" — even if it had previously committed
--     to vertical_allowed. This is checked every event so a long
--     horizontal sweep with vertical drift, OR a vertical scroll that
--     starts to drift sideways, both end up suppressing vertical for the
--     rest of the gesture. There is no escape from horizontal_only without
--     a SCROLL_GESTURE_GAP_MS pause to reset the gesture.
--   • A pause of SCROLL_GESTURE_GAP_MS (wall-clock) resets the gesture and
--     a fresh classification can occur.
--
-- @file scroll_axis_lock.lua
local M = {}
local ui_constants = require("core.ui_constants")

local GESTURE_GAP_MS = ui_constants.TIMELINE.SCROLL_GESTURE_GAP_MS
local VERTICAL_INTENT_PX = ui_constants.TIMELINE.SCROLL_VERTICAL_INTENT_PX
local HORIZONTAL_COMMIT_PX = ui_constants.TIMELINE.SCROLL_HORIZONTAL_COMMIT_PX

assert(type(GESTURE_GAP_MS) == "number" and GESTURE_GAP_MS > 0,
    "scroll_axis_lock: ui_constants.TIMELINE.SCROLL_GESTURE_GAP_MS must be > 0")
assert(type(VERTICAL_INTENT_PX) == "number" and VERTICAL_INTENT_PX > 0,
    "scroll_axis_lock: ui_constants.TIMELINE.SCROLL_VERTICAL_INTENT_PX must be > 0")
assert(type(HORIZONTAL_COMMIT_PX) == "number" and HORIZONTAL_COMMIT_PX > 0,
    "scroll_axis_lock: ui_constants.TIMELINE.SCROLL_HORIZONTAL_COMMIT_PX must be > 0")

-- Per-view state-table shape. `mode` takes one of:
--   "tentative"        — gesture in progress, no commitment yet (vertical suppressed)
--   "horizontal_only"  — committed to horizontal; vertical stays suppressed (sticky)
--   "vertical_allowed" — committed to vertical; both axes pass through (until cum_dx
--                        crosses the horizontal threshold and ratchets back)
--
-- frac_x carries the unconverted sub-frame fractional viewport-start delta
-- across events within a single gesture. Resets on the same gesture-gap
-- threshold as `mode`, so a fresh gesture never inherits residual fraction
-- from the previous one (which would surface as a ghost-jump on the first
-- post-pause event). Owned here because the gesture lifecycle already
-- lives in this module.

--- Create a fresh per-view state table.
function M.new_state()
    return { mode = "tentative", cum_dx = 0, cum_dy = 0, frac_x = 0, last_ts = nil }
end

-- Reset the gesture if the inter-event pause exceeds GESTURE_GAP_MS.
local function reset_if_gesture_gap(state, now_ms)
    if state.last_ts ~= nil and (now_ms - state.last_ts) > GESTURE_GAP_MS then
        state.mode = "tentative"
        state.cum_dx = 0
        state.cum_dy = 0
        state.frac_x = 0
    end
    state.last_ts = now_ms
end

-- Add this event's magnitudes to the cumulative tally for the gesture.
local function accumulate_motion(state, dx, dy)
    state.cum_dx = state.cum_dx + math.abs(dx)
    state.cum_dy = state.cum_dy + math.abs(dy)
end

-- Update the gesture mode given accumulated motion. The horizontal ratchet
-- is checked every event so a vertical_allowed gesture that starts
-- drifting sideways past the threshold also reclaims to horizontal_only —
-- vertical drift on a horizontal swipe never wins. There is no escape
-- from horizontal_only without a wall-clock pause to reset the gesture.
local function update_mode(state)
    if state.cum_dx >= HORIZONTAL_COMMIT_PX then
        state.mode = "horizontal_only"
    elseif state.mode == "tentative" and state.cum_dy >= VERTICAL_INTENT_PX then
        state.mode = "vertical_allowed"
    end
end

--- Apply asymmetric axis-suppression to an incoming (dx, dy) wheel delta pair.
--
-- Horizontal is always returned unchanged. Vertical is returned only when
-- the gesture is currently in vertical_allowed AND has not been ratcheted
-- into horizontal_only by accumulated horizontal motion.
--
-- @param state   table created by new_state(); mutated in place
-- @param dx      incoming horizontal delta
-- @param dy      incoming vertical delta
-- @param now_ms  monotonic wall-clock timestamp in milliseconds for this event
-- @return (effective_dx, effective_dy) after suppression
function M.apply(state, dx, dy, now_ms)
    reset_if_gesture_gap(state, now_ms)
    accumulate_motion(state, dx, dy)
    update_mode(state)

    if state.mode == "vertical_allowed" then
        return dx, dy
    end
    return dx, 0
end

return M
