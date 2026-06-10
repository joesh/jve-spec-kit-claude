--- Timeline zoom scroller: the thumb mirrors the visible time window;
-- dragging it pans, dragging either thumb END zooms with the opposite
-- window edge anchored (Premiere-style), clicking the track pages.
--
-- Domain contract under test (no implementation names): the scroller
-- at the bottom of the timeline represents the visible time window
-- within the scrollable extent, proportionally — thumb position is the
-- window's left edge, thumb width its duration. Dragging the middle
-- moves the window by the drag distance at the scroller's scale
-- (whole extent across the track width). Dragging the right end
-- stretches the window with its left edge pinned; the left end, with
-- its right edge pinned. The window can never get narrower than the
-- zoom limit. Clicking the empty track jumps one window toward the
-- click.
--
-- Run: ./build/bin/jve --test tests/synthetic/integration/test_timeline_zoom_scroller.lua

local ui = require("synthetic.integration.ui_test_env")

print("=== test_timeline_zoom_scroller ===")

local _, info = ui.launch({
    project_name = "Zoom Scroller Test",
})
local db_path = info.db_path

local state = require("ui.timeline.timeline_state")
local panel = require("ui.timeline.timeline_panel")

ui.pump(300)

local scroller = panel.timeline_zoom_scroller
assert(scroller, "timeline panel has no zoom scroller")

local function window()
    local start = state.get_viewport_start_time()
    local duration = state.get_viewport_duration()
    assert(start and duration, "no visible time window")
    return start, duration
end

-- The scroller's px↔frame scale, computed from observables: the whole
-- scrollable extent maps across the track width.
local function scroller_scale(track_w)
    local floor = state.get_start_timecode_frame()
    local extent = state.get_timeline_extent()
    return track_w / (extent - floor), floor
end

local function drag(from_x, to_x)
    scroller.on_mouse_event("press", from_x, 7, 1, {})
    scroller.on_mouse_event("move", to_x, 7, 1, {})
    scroller.on_mouse_event("release", to_x, 7, 1, {})
    ui.pump(50)
end

-- ── 1. Thumb mirrors the window proportionally ───────────────────────
do
    local g = scroller.geometry()
    assert(g, "scroller has no geometry — widget not realized?")
    local start, duration = window()
    local scale, floor = scroller_scale(g.width)
    local expect_x = (start - floor) * scale
    local expect_w = duration * scale
    assert(math.abs(g.thumb_x - expect_x) <= 1, string.format(
        "thumb position must be the window's left edge at the extent "
        .. "scale: thumb_x=%.1f expected=%.1f", g.thumb_x, expect_x))
    assert(math.abs(g.thumb_w - math.max(24, expect_w)) <= 1, string.format(
        "thumb width must be the window's duration at the extent scale: "
        .. "thumb_w=%.1f expected=%.1f", g.thumb_w, expect_w))
    print(string.format("  thumb mirrors window: x=%.0f w=%.0f track=%d",
        g.thumb_x, g.thumb_w, g.width))
end

-- ── 2. Dragging the thumb middle pans the window ─────────────────────
do
    local g = scroller.geometry()
    local start = window()
    local scale = scroller_scale(g.width)
    local mid = g.thumb_x + g.thumb_w / 2
    local DX = 60  -- non-trivial, keeps the thumb on the track
    drag(mid, mid + DX)
    local new_start = window()
    local expected = start + math.floor(DX / scale + 0.5)
    assert(math.abs(new_start - expected) <= 1, string.format(
        "dragging the thumb +%dpx must pan the window from %d to ~%d; "
        .. "got %d", DX, start, expected, new_start))
    print(string.format("  thumb drag pans: %d -> %d", start, new_start))
end

-- ── 3. Dragging the RIGHT end zooms out, left edge pinned ────────────
do
    local g = scroller.geometry()
    local start, duration = window()
    local scale = scroller_scale(g.width)
    local right_end = g.thumb_x + g.thumb_w - 2
    local DX = 80
    drag(right_end, right_end + DX)
    local new_start, new_duration = window()
    assert(new_start == start, string.format(
        "right-end drag must pin the window's left edge: was %d, now %d",
        start, new_start))
    local expected_dur = duration + math.floor(DX / scale + 0.5)
    assert(math.abs(new_duration - expected_dur) <= 1, string.format(
        "right-end drag +%dpx must stretch the window from %d to ~%d "
        .. "frames; got %d", DX, duration, expected_dur, new_duration))
    print(string.format("  right-end drag zooms out, left edge pinned: "
        .. "%d -> %d frames", duration, new_duration))
end

-- ── 4. Dragging the LEFT end zooms, right edge pinned ────────────────
do
    -- Need room on the left: the previous cases left the window away
    -- from the sequence start; verify, else pan right first.
    local start, duration = window()
    local right_edge = start + duration
    local g = scroller.geometry()
    local scale = scroller_scale(g.width)
    local left_end = g.thumb_x + 2
    local DX = 40
    assert(start - math.floor(DX / scale + 0.5) >= 0,
        "test setup: window must sit far enough right for a left-end "
        .. "outward drag — adjust earlier cases")
    drag(left_end, left_end - DX)
    local new_start, new_duration = window()
    assert(new_start + new_duration == right_edge, string.format(
        "left-end drag must pin the window's right edge at %d; now ends "
        .. "at %d", right_edge, new_start + new_duration))
    local expected_dur = duration + math.floor(DX / scale + 0.5)
    assert(math.abs(new_duration - expected_dur) <= 1, string.format(
        "left-end drag -%dpx must stretch the window from %d to ~%d "
        .. "frames; got %d", DX, duration, expected_dur, new_duration))
    print(string.format("  left-end drag zooms out, right edge pinned: "
        .. "%d -> %d frames", duration, new_duration))
end

-- ── 5. The window can't shrink below the zoom limit ──────────────────
do
    local g = scroller.geometry()
    local right_end = g.thumb_x + g.thumb_w - 2
    -- Drag the right end all the way to (and past) the thumb's left
    -- edge — far more shrink than the limit allows.
    drag(right_end, g.thumb_x - g.width)
    local _, new_duration = window()
    assert(new_duration == 30, string.format(
        "shrinking past the zoom limit must clamp the window to 30 "
        .. "frames; got %d", new_duration))
    print("  zoom-in clamps at the 30-frame limit")
end

-- ── 6. Clicking the empty track pages toward the click ───────────────
do
    local start, duration = window()
    local g = scroller.geometry()
    -- Click well right of the thumb.
    local click_x = math.min(g.width - 2, g.thumb_x + g.thumb_w + 100)
    assert(click_x > g.thumb_x + g.thumb_w,
        "test setup: no track space right of thumb to click")
    scroller.on_mouse_event("press", click_x, 7, 1, {})
    scroller.on_mouse_event("release", click_x, 7, 1, {})
    ui.pump(50)
    local new_start = window()
    assert(new_start == start + duration, string.format(
        "clicking the track right of the thumb must page the window "
        .. "forward one duration: %d + %d -> expected %d, got %d",
        start, duration, start + duration, new_start))
    print(string.format("  track click pages forward: %d -> %d",
        start, new_start))
end

require("synthetic.helpers.blank_project").cleanup(db_path)
ui.cleanup()
print("✅ test_timeline_zoom_scroller.lua passed")
