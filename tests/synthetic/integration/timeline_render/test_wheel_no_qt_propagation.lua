--- Domain rule: wheel events on the timeline view must NEVER propagate to
-- Qt's parent QScrollArea. The C++ side consults the Lua handler's return
-- value to decide whether to forward the event; returning true would let
-- Qt scroll the widget independently of the model — a single-owner
-- violation (scroll state is model-owned, 2026-06-09 redesign).
--
-- Observable: the registered tl_mouse_* global returns boolean false for
-- every wheel event, regardless of direction or magnitude.
--
-- Replaces: tests/synthetic/lua/test_wheel_handler_returns_bool.lua
-- (that test called input.handle_wheel() directly on a mock view;
-- this version fires the event through the real registered handler global
-- — the same path C++ takes — to guard the actual contract boundary).

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_wheel_no_qt_propagation ===")

env.boot()
local widget = env.video_widget()

-- All assertions share one fresh sequence so the view is initialized.
env.fresh_sequence("WheelProp")
env.view_frames(300, 0)

local h = env.mouse_handler(widget)

-- ── helper: assert a wheel event returns boolean false ───────────────────────
local function assert_returns_false(label, event)
    local ret = h(event)
    assert(type(ret) == "boolean", string.format(
        "%s: tl_mouse_* must return a boolean for wheel events (C++ reads it "
        .. "to decide Qt propagation); got %s", label, type(ret)))
    assert(ret == false, string.format(
        "%s: tl_mouse_* must return false — vertical scroll goes through the "
        .. "model write path and must never be forwarded to QWidget::wheelEvent; "
        .. "got %s", label, tostring(ret)))
end

-- ── Scenario A: horizontal-dominant gesture ──────────────────────────────────
print("  A: horizontal-dominant wheel events return false")
do
    -- Five events of pure-horizontal motion; axis lock pins horizontal_only.
    for i = 1, 5 do
        assert_returns_false(
            string.format("A[%d]", i),
            { type = "wheel", delta_x = 10, delta_y = 1,
              modifiers = {}, scroll_phase = nil })
    end
    print("    OK")
end

-- ── Scenario B: pure-vertical gesture ────────────────────────────────────────
print("  B: vertical wheel events return false")
do
    -- Wait out the real wall-clock gesture gap (SCROLL_GESTURE_GAP_MS =
    -- 150ms) so the axis lock starts a fresh gesture instead of staying
    -- pinned to scenario A's horizontal lock.
    env.pump(require("core.ui_constants").TIMELINE.SCROLL_GESTURE_GAP_MS + 100)

    for i = 1, 8 do
        assert_returns_false(
            string.format("B[%d]", i),
            { type = "wheel", delta_x = 0, delta_y = 8,
              modifiers = {}, scroll_phase = nil })
    end
    print("    OK")
end

-- ── Scenario C: large-magnitude events still return false ────────────────────
print("  C: large wheel delta still returns false")
do
    assert_returns_false("C large-dx",
        { type = "wheel", delta_x = 500, delta_y = 0,
          modifiers = {}, scroll_phase = nil })
    assert_returns_false("C large-dy",
        { type = "wheel", delta_x = 0, delta_y = 500,
          modifiers = {}, scroll_phase = nil })
    print("    OK")
end

print("✅ test_wheel_no_qt_propagation.lua passed")
