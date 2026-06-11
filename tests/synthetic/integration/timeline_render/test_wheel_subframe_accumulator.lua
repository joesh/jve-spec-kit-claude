--- Domain rule: at high zoom (few frames visible), individual trackpad-
-- wheel events contribute sub-frame viewport deltas. They must accumulate
-- across events so the user can scroll at all. The accumulator must also
-- be symmetric (both directions work) and must reset after a gesture-gap
-- pause so one gesture's residual cannot ghost-jump into the next.
--
-- Math: delta_frames_per_event = (-dx / widget_width) * viewport_duration
-- At the fixture zoom (viewport=60 frames, widget ≈ 1434 px) dx=12 gives
-- ≈ 0.502 frames per event — two events accumulate to > 1 → one
-- whole-frame advance.
--
-- Observable: state.get_viewport_start_time() before and after the
-- burst of wheel events delivered through the real tl_mouse_* handler.
--
-- Replaces: tests/synthetic/lua/test_wheel_subframe_accumulator.lua
-- (that test used mock_state + a patched timeline_state module setter;
-- this version reads the real viewport state through the real command path).
--
-- Clock note: the gesture gap is wall-clock (SCROLL_GESTURE_GAP_MS = 150ms),
-- short enough to wait out for real — env.pump(GAP_MS + margin) between
-- gestures, no patched clock. Events fired back-to-back within a burst are
-- microseconds apart, far inside the same gesture window.

local env  = require("synthetic.integration.timeline_render.render_env")
local ui_c = require("core.ui_constants")

print("=== test_wheel_subframe_accumulator ===")

env.boot()
local state  = env.context().state
local widget = env.video_widget()

-- ── Fixture zoom: 60 frames visible. ─────────────────────────────────────────
-- At widget width ≈ 1434 px: dx=12 → delta_time ≈ 0.502 frames/event
-- (sub-frame, so one event alone never advances). Two consecutive events
-- accumulate ≈ 1.004 → modf yields whole=1, residual≈0.004 → one advance.
--
-- ZoomTimelineViewport anchors zoom at a fractional pixel position; the
-- resulting viewport_start depends on the prior state and is not 500 exactly.
-- Tests capture start_before after view_frames and assert relative changes.
local VIEWPORT_DUR = 60
local SUB_FRAME_DX = 12   -- gives ≈ 0.5 frames/event at this zoom

env.fresh_sequence("Subframe")
env.view_frames(VIEWPORT_DUR, 0)

local h = env.mouse_handler(widget)

local GAP_MS = ui_c.TIMELINE.SCROLL_GESTURE_GAP_MS
assert(type(GAP_MS) == "number" and GAP_MS > 0,
    "subframe test: SCROLL_GESTURE_GAP_MS missing from ui_constants.TIMELINE")

-- Wait out the real wall-clock gesture gap so the axis lock treats the
-- next wheel event as a fresh gesture (and discards any residual).
local function wait_out_gesture_gap()
    env.pump(GAP_MS + 100)
end

-- Reset the viewport to the fixture zoom between scenarios, position it
-- at frame 200 (room on both sides of the clamp boundary at frame 0;
-- same setter ScrollTimelineViewport uses), and wait out the gesture gap
-- so the first wheel event starts a fresh gesture.
local function reset_viewport()
    env.view_frames(VIEWPORT_DUR, 0)
    state.set_viewport_start_time(200)
    wait_out_gesture_gap()
end

-- ── Scenario A: sub-frame events accumulate into a real advance (left) ───────
-- dx>0 pushes content right → viewport scrolls left (start decreases).
-- Two events of +SUB_FRAME_DX each contribute ~0.5 frames → together > 1.
print("  A: sub-frame LEFT events accumulate; viewport start decreases")
do
    reset_viewport()
    local start_before = state.get_viewport_start_time()
    assert(type(start_before) == "number",
        "A: setup: get_viewport_start_time must return a number")

    -- ScrollTimelineViewport dispatches synchronously; no Qt pump needed.
    h({ type = "wheel", delta_x = SUB_FRAME_DX, delta_y = 0,
        modifiers = {}, scroll_phase = nil })
    h({ type = "wheel", delta_x = SUB_FRAME_DX, delta_y = 0,
        modifiers = {}, scroll_phase = nil })

    local start_after = state.get_viewport_start_time()
    assert(start_after < start_before, string.format(
        "A: two sub-frame dx=%d events must accumulate into observable "
        .. "leftward scroll (start_after < start_before); before=%d after=%d",
        SUB_FRAME_DX, start_before, start_after))
    print("    OK (delta = " .. tostring(start_before - start_after) .. " frames)")
end

-- ── Scenario B: sub-frame events accumulate in the RIGHT direction ────────────
-- dx<0 pushes content left → viewport scrolls right (start increases).
-- The original bug (floor rounding toward −∞) stalled this direction.
print("  B: sub-frame RIGHT events accumulate; viewport start increases")
do
    reset_viewport()
    local start_before = state.get_viewport_start_time()

    h({ type = "wheel", delta_x = -SUB_FRAME_DX, delta_y = 0,
        modifiers = {}, scroll_phase = nil })
    h({ type = "wheel", delta_x = -SUB_FRAME_DX, delta_y = 0,
        modifiers = {}, scroll_phase = nil })

    local start_after = state.get_viewport_start_time()
    assert(start_after > start_before, string.format(
        "B: two sub-frame dx=-%d events must accumulate into observable "
        .. "rightward scroll (start_after > start_before) — the pre-fix floor "
        .. "rounding stalled this direction; before=%d after=%d",
        SUB_FRAME_DX, start_before, start_after))
    print("    OK (delta = +" .. tostring(start_after - start_before) .. " frames)")
end

-- ── Scenario C: direction reversal cancels the accumulated fraction ───────────
-- One sub-frame right-swipe builds residual, one equal left-swipe cancels it.
-- Net motion must be zero — the residue from the right swipe must not ghost
-- into the left-swipe's accumulation.
print("  C: immediate direction-reversal cancels accumulated fraction; net motion = 0")
do
    reset_viewport()
    local start_before = state.get_viewport_start_time()

    -- One sub-frame event: contributes ~0.502 frames but doesn't cross 1.
    h({ type = "wheel", delta_x = -SUB_FRAME_DX, delta_y = 0,
        modifiers = {}, scroll_phase = nil })
    local after_partial = state.get_viewport_start_time()

    -- Immediate same-magnitude reverse in the same gesture window.
    h({ type = "wheel", delta_x = SUB_FRAME_DX, delta_y = 0,
        modifiers = {}, scroll_phase = nil })
    local after_reversal = state.get_viewport_start_time()

    -- Neither event triggered a whole-frame advance; the reversal cancels
    -- the fraction (math.modf truncates toward zero for both signs).
    assert(after_partial == start_before, string.format(
        "C: single sub-frame event must not advance the viewport on its own; "
        .. "start_before=%d after_partial=%d", start_before, after_partial))
    assert(after_reversal == start_before, string.format(
        "C: direction-reversal must cancel the fraction from the prior event — "
        .. "net motion must be zero; start_before=%d after_reversal=%d",
        start_before, after_reversal))
    print("    OK")
end

-- ── Scenario D: gesture-gap pause resets the accumulator ─────────────────────
-- One sub-frame event builds residual < 1 frame. After a pause longer than
-- SCROLL_GESTURE_GAP_MS, another sub-frame event starts fresh — the prior
-- residual is discarded, so the second event alone also < 1 frame → no advance.
print("  D: gesture-gap resets accumulator; post-pause event starts fresh")
do
    reset_viewport()
    local start_at_entry = state.get_viewport_start_time()

    -- Gesture A: one sub-frame event → builds ~0.502 frame residual, no advance.
    h({ type = "wheel", delta_x = -SUB_FRAME_DX, delta_y = 0,
        modifiers = {}, scroll_phase = nil })
    local after_gesture_a = state.get_viewport_start_time()
    assert(after_gesture_a == start_at_entry, string.format(
        "D: setup: single sub-frame event must not advance by itself; "
        .. "start=%d after=%d", start_at_entry, after_gesture_a))

    -- Gap: wait out SCROLL_GESTURE_GAP_MS for real → axis lock resets,
    -- discarding the ~0.502 frame residual from gesture A.
    wait_out_gesture_gap()

    -- Gesture B: one fresh sub-frame event — starts from a clean accumulator.
    -- ~0.502 frames < 1 → no advance; without the reset the inherited residual
    -- ~0.502 + ~0.502 > 1 would produce a ghost-jump here.
    h({ type = "wheel", delta_x = -SUB_FRAME_DX, delta_y = 0,
        modifiers = {}, scroll_phase = nil })
    local after_gesture_b = state.get_viewport_start_time()
    assert(after_gesture_b == start_at_entry, string.format(
        "D: post-gap sub-frame event must not inherit prior gesture's residual "
        .. "(expected no advance from %d); got %d",
        start_at_entry, after_gesture_b))
    print("    OK")
end

print("✅ test_wheel_subframe_accumulator.lua passed")
