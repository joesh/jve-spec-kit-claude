-- Integration: focus_manager paints focus borders via the focusBorderColor
-- dynamic property (read by StyledWidget::paintEvent), NOT via stylesheets
-- and NOT via child overlay widgets.
--
-- The two regressions this pins:
--   1. Stylesheet border rules don't render reliably on macOS Qt6 with Metal.
--      Focus border must come from a dynamic property the paintEvent reads.
--   2. Earlier focus_manager versions created child QWidgets as border
--      overlays. On macOS those become native NSViews and occlude the Metal
--      surface beneath them — black flicker on every focus change.
--
-- Replaces the prior mock-based test that only spied on which qt binding
-- focus_manager *called*. Verifying that focusBorderColor is *actually set*
-- on a real widget, AND that no new widget children appeared, pins the
-- behavior rather than the implementation.

print("=== test_focus_manager.lua ===")

require("test_env")
local focus_manager  = require("ui.focus_manager")
local ui_constants   = require("core.ui_constants")

local FOCUS_COLOR   = ui_constants.COLORS.FOCUS_BORDER_COLOR
local UNFOCUS_COLOR = "#2d2d2d"  -- matches focus_manager's COLORS.unfocused_border

local function make_panel(name)
    local w = qt_constants.WIDGET.CREATE()
    assert(w, "WIDGET.CREATE returned nil for " .. name)
    return w
end

-- Build four real StyledWidget panels (WIDGET.CREATE returns StyledWidget).
local browser_w   = make_panel("browser")
local source_w    = make_panel("source_monitor")
local timeline_w  = make_panel("timeline_monitor")
local inspector_w = make_panel("inspector")

-- Snapshot child counts BEFORE registration — the overlay-regression
-- check compares post-focus counts back against this baseline.
local baseline_children = {
    [browser_w]   = qt_widget_child_widget_count(browser_w),
    [source_w]    = qt_widget_child_widget_count(source_w),
    [timeline_w]  = qt_widget_child_widget_count(timeline_w),
    [inspector_w] = qt_widget_child_widget_count(inspector_w),
}

focus_manager.register_panel("project_browser",  browser_w,   nil, "Browser")
focus_manager.register_panel("source_monitor",   source_w,    nil, "Source")
focus_manager.register_panel("timeline_monitor", timeline_w,  nil, "Timeline")
focus_manager.register_panel("inspector",        inspector_w, nil, "Inspector")

-- Match layout.lua: seed every panel to unfocused before the first focus
-- change. Without this, set_focused_panel only updates old + new panels,
-- leaving never-focused siblings with nil focusBorderColor (production
-- state is identical for the first frame, but layout.lua calls this on
-- bootstrap so the visible state always has all panels initialized).
focus_manager.initialize_all_panels()

-- ── (1) Focused panel gets FOCUS_BORDER_COLOR; others get unfocused ───
print("-- (1) focused vs unfocused property values --")
focus_manager.set_focused_panel("project_browser")
assert(qt_get_widget_property(browser_w, "focusBorderColor") == FOCUS_COLOR,
    "focused panel must carry FOCUS_BORDER_COLOR; got "
    .. tostring(qt_get_widget_property(browser_w, "focusBorderColor")))
for _, w in ipairs({source_w, timeline_w, inspector_w}) do
    local v = qt_get_widget_property(w, "focusBorderColor")
    assert(v == UNFOCUS_COLOR, "unfocused panel must carry "
        .. UNFOCUS_COLOR .. "; got " .. tostring(v))
end
print("  PASS browser focused, others unfocused")

-- ── (2) Focus change repaints both old and new panel ──────────────────
print("-- (2) focus change updates both old and new --")
focus_manager.set_focused_panel("timeline_monitor")
assert(qt_get_widget_property(timeline_w, "focusBorderColor") == FOCUS_COLOR,
    "newly focused timeline must carry FOCUS_BORDER_COLOR")
assert(qt_get_widget_property(browser_w, "focusBorderColor") == UNFOCUS_COLOR,
    "previously focused browser must revert to unfocused color")
print("  PASS timeline now focused, browser reverted")

-- ── (3) get_focused_panel returns the active id ───────────────────────
print("-- (3) get_focused_panel matches set_focused_panel --")
assert(focus_manager.get_focused_panel() == "timeline_monitor",
    "get_focused_panel must return the currently focused id")
focus_manager.set_focused_panel("inspector")
assert(focus_manager.get_focused_panel() == "inspector",
    "get_focused_panel must track set_focused_panel")
print("  PASS")

-- ── (4) No child overlay widgets created on any panel ─────────────────
-- The overlay regression: focus_manager used to add a separate QWidget
-- child to draw the border. On macOS those became NSViews and occluded
-- the Metal surface. Per-widget child counts must equal the pre-register
-- baseline after any number of focus changes.
print("-- (4) no child overlay widgets created --")
-- Exercise focus across every panel to maximize chances any overlay
-- creation would have fired.
for _, id in ipairs({"project_browser", "source_monitor", "timeline_monitor", "inspector"}) do
    focus_manager.set_focused_panel(id)
end
for w, baseline in pairs(baseline_children) do
    local now = qt_widget_child_widget_count(w)
    assert(now == baseline, string.format(
        "panel widget child count grew from %d to %d — overlay regression: "
        .. "focus_manager must not parent any widget to the panel widget; "
        .. "borders come from focusBorderColor dynamic property only",
        baseline, now))
end
print("  PASS all panel widgets retain baseline child count")

print("\nPASS test_focus_manager.lua")
