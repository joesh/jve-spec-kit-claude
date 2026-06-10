--- Horizontal timeline scrollbar: pans the visible time window across
-- both track lanes, same as a horizontal wheel gesture.
--
-- Domain contract under test (no implementation names): the bar at the
-- bottom of the timeline represents the visible time window within the
-- scrollable extent — its thumb size is the window's duration, its
-- position the window's left edge. Dragging it moves the window (both
-- lanes and the ruler follow, since they all render from the same
-- window); panning by wheel moves the thumb. Dragging past the end of
-- content stops at the scrollable limit.
--
-- Run: ./build/bin/jve --test tests/synthetic/integration/test_timeline_h_scrollbar.lua

local ui = require("synthetic.integration.ui_test_env")

print("=== test_timeline_h_scrollbar ===")

local _, info = ui.launch({
    project_name = "H Scrollbar Test",
})
local db_path = info.db_path

local command_manager = require("core.command_manager")
local state = require("ui.timeline.timeline_state")
local panel = require("ui.timeline.timeline_panel")

ui.pump(300)

assert(panel.timeline_h_scrollbar,
    "timeline panel has no horizontal scrollbar widget")

-- luacheck: globals qt_get_scroll_bar_metrics
local function bar()
    local value, min, max, page = qt_get_scroll_bar_metrics(panel.timeline_h_scrollbar)
    return { value = value, min = min, max = max, page = page }
end

-- The visible time window the ruler and lanes render from.
local function window()
    return state.get_viewport_start_time(), state.get_viewport_duration()
end

-- ── 1. Thumb mirrors the visible window ──────────────────────────────
do
    local start, duration = window()
    assert(start and duration, "no visible time window after launch")
    local b = bar()
    assert(b.value == start, string.format(
        "thumb position must be the window's left edge: bar=%s window=%s",
        tostring(b.value), tostring(start)))
    assert(b.page == duration, string.format(
        "thumb size must be the window's duration: bar=%s window=%s",
        tostring(b.page), tostring(duration)))
    assert(b.max >= b.min, "bar range inverted")
    print(string.format("  thumb mirrors window: value=%d page=%d range=[%d,%d]",
        b.value, b.page, b.min, b.max))
end

-- ── 2. Dragging the bar pans the window ──────────────────────────────
-- user_scroll_timeline_to is the gesture entry point a thumb drag lands
-- on (same boundary pattern as the vertical panes' user_scroll_pane_to).
do
    local start, duration = window()
    local target = start + math.floor(duration / 2)  -- non-trivial, in-range
    panel.user_scroll_timeline_to(target)
    ui.pump(50)
    local new_start = state.get_viewport_start_time()
    assert(new_start == target, string.format(
        "dragging the bar to %d must move the window's left edge there; "
        .. "window now starts at %s", target, tostring(new_start)))
    local b = bar()
    assert(b.value == target, string.format(
        "thumb must sit where it was dragged: bar=%s target=%d",
        tostring(b.value), target))
    print(string.format("  drag to %d pans the window: OK", target))
end

-- ── 3. Wheel pan moves the thumb ─────────────────────────────────────
do
    local start = state.get_viewport_start_time()
    local DELTA = 24
    local r = command_manager.execute("ScrollTimelineViewport", {
        delta_frames = DELTA,
    })
    assert(r and r.success, "ScrollTimelineViewport failed: "
        .. tostring(r and r.error_message or "(nil)"))
    ui.pump(50)
    local b = bar()
    assert(b.value == start + DELTA, string.format(
        "wheel pan of +%d frames must move the thumb from %d to %d; bar=%s",
        DELTA, start, start + DELTA, tostring(b.value)))
    print("  wheel pan moves the thumb: OK")
end

-- ── 4. Dragging past the end clamps and the thumb snaps back ─────────
do
    local _, duration = window()
    local b_before = bar()
    local way_past = b_before.max + duration * 100
    panel.user_scroll_timeline_to(way_past)
    ui.pump(50)
    local new_start = state.get_viewport_start_time()
    local b = bar()
    -- The window cannot start beyond the scrollable limit, and the thumb
    -- must reflect the clamped position, not the over-drag.
    assert(new_start <= b.max, string.format(
        "window start %d exceeds scrollable limit %d after over-drag",
        new_start, b.max))
    assert(b.value == new_start, string.format(
        "thumb must snap to the clamped position: bar=%s window=%d",
        tostring(b.value), new_start))
    print(string.format("  over-drag clamps to %d, thumb follows: OK", new_start))
end

require("synthetic.helpers.blank_project").cleanup(db_path)
ui.cleanup()
print("✅ test_timeline_h_scrollbar.lua passed")
