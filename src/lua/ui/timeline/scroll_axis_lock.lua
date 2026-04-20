--- scroll_axis_lock.lua — per-gesture axis lock for trackpad wheel events.
--
-- Trackpad scroll gestures are rarely perfectly axis-aligned; a gesture the
-- user intends as pure horizontal usually has small vertical drift, and vice
-- versa. Without hysteresis, that drift reads as orthogonal scrolling on the
-- other axis and feels like "the timeline scrolled sideways when I was
-- scrolling the tracks list".
--
-- Semantics:
--   • A gesture is a run of wheel events separated by no more than
--     SCROLL_GESTURE_GAP_MS ms. Longer gaps start a new gesture.
--   • When the first event of a gesture has one axis clearly dominating
--     (magnitude ratio ≥ SCROLL_AXIS_LOCK_RATIO), the gesture locks to that
--     axis and the orthogonal delta is zeroed for the rest of the gesture.
--   • If no axis dominates on the first event, the gesture stays unlocked
--     and both axes pass through. A later event in the same gesture can
--     establish the lock.
--   • Once locked, the orthogonal axis is suppressed even when a later event
--     in the gesture happens to be orthogonal-dominant.
--
-- Design rationale: the lock is per-gesture, not per-event, and not per-view.
-- The caller holds the per-view state table and passes it in. This keeps the
-- module pure and trivially testable.
--
-- @file scroll_axis_lock.lua
local M = {}
local ui_constants = require("core.ui_constants")

local LOCK_RATIO = ui_constants.TIMELINE.SCROLL_AXIS_LOCK_RATIO
local GESTURE_GAP_MS = ui_constants.TIMELINE.SCROLL_GESTURE_GAP_MS

assert(type(LOCK_RATIO) == "number" and LOCK_RATIO > 1,
    "scroll_axis_lock: ui_constants.TIMELINE.SCROLL_AXIS_LOCK_RATIO must be > 1")
assert(type(GESTURE_GAP_MS) == "number" and GESTURE_GAP_MS > 0,
    "scroll_axis_lock: ui_constants.TIMELINE.SCROLL_GESTURE_GAP_MS must be > 0")

--- Create a fresh per-view state table.
function M.new_state()
    return { axis = nil, last_ts = nil }
end

--- Apply axis lock to an incoming (dx, dy) wheel delta pair.
--
-- @param state   table created by new_state(); mutated in place
-- @param dx      incoming horizontal delta
-- @param dy      incoming vertical delta
-- @param now_ms  monotonic timestamp in milliseconds for this event
-- @return (effective_dx, effective_dy) after axis-lock suppression
function M.apply(state, dx, dy, now_ms)
    if state.last_ts ~= nil and (now_ms - state.last_ts) > GESTURE_GAP_MS then
        state.axis = nil
    end
    state.last_ts = now_ms

    if state.axis == nil then
        local adx = math.abs(dx)
        local ady = math.abs(dy)
        if adx > ady * LOCK_RATIO then
            state.axis = "h"
        elseif ady > adx * LOCK_RATIO then
            state.axis = "v"
        end
    end

    if state.axis == "h" then return dx, 0 end
    if state.axis == "v" then return 0, dy end
    return dx, dy
end

return M
