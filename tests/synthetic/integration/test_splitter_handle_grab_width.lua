-- Integration: the main-window stylesheet gives every splitter handle a
-- grab target at least SPLITTER_HANDLE_GRAB_PX thick on its divider axis.
--
-- Regression for the "first drag fails / horizontal splitter won't move"
-- report: the old generic `QSplitter::handle { width; height }` rule set the
-- WRONG axis per orientation (width is thickness only for a horizontal
-- splitter's vertical bar; height is thickness only for a vertical splitter's
-- horizontal bar), leaving a ~2px rendered handle. The split cursor shows
-- wider than that, so presses that felt on-target hit-tested onto the adjacent
-- panel and the drag was dropped. The fix is two orientation-specific rules,
-- each setting the divider-axis dimension to SPLITTER_HANDLE_GRAB_PX.
--
-- Black-box: builds real QSplitters with the production stylesheet and asserts
-- the rendered handle thickness — no reference to the rule strings themselves.

print("=== test_splitter_handle_grab_width.lua ===")

require("test_env")
local ui_constants = require("core.ui_constants")
local pump = require("synthetic.helpers.qt_event_pump").pump

local GRAB = ui_constants.WINDOW.SPLITTER_HANDLE_GRAB_PX
assert(type(GRAB) == "number" and GRAB > 0, "SPLITTER_HANDLE_GRAB_PX must be a positive number")

local function make_widget()
    local w = qt_constants.WIDGET.CREATE()
    assert(w, "WIDGET.CREATE returned nil")
    return w
end

-- Two children each so a handle exists at index 1.
local function build_splitter(orientation)
    local s = qt_constants.LAYOUT.CREATE_SPLITTER(orientation)
    qt_constants.LAYOUT.ADD_WIDGET(s, make_widget())
    qt_constants.LAYOUT.ADD_WIDGET(s, make_widget())
    return s
end

-- Mirror layout.lua: main_splitter (vertical) wraps top_splitter (horizontal).
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_SIZE(main_window, 1200, 900)

local top_splitter  = build_splitter("horizontal")
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, top_splitter)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, make_widget())

qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)

-- The production stylesheet carries the orientation-specific handle rules.
qt_set_widget_stylesheet(main_window, ui_constants.STYLES.MAIN_WINDOW_TITLE_BAR)

qt_constants.DISPLAY.SHOW(main_window)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {450, 450})
qt_constants.LAYOUT.SET_SPLITTER_SIZES(top_splitter, {600, 600})
pump(200)

local function handle_thickness(splitter, axis_prop)
    local handle = qt_get_splitter_handle(splitter, 1)
    assert(handle, "splitter must expose a handle at index 1")
    local v = qt_get_widget_property(handle, axis_prop)
    assert(v, "handle "..axis_prop.." property missing")
    return tonumber(v)
end

-- Horizontal splitter -> vertical bar -> WIDTH is the divider thickness.
local top_thick = handle_thickness(top_splitter, "width")
-- Vertical splitter -> horizontal bar -> HEIGHT is the divider thickness.
local main_thick = handle_thickness(main_splitter, "height")

print(string.format("grab=%d  top(horizontal) handle width=%d  main(vertical) handle height=%d",
    GRAB, top_thick, main_thick))

assert(top_thick >= GRAB, string.format(
    "horizontal splitter handle too thin to grab: width=%d < %d", top_thick, GRAB))
assert(main_thick >= GRAB, string.format(
    "vertical splitter handle too thin to grab: height=%d < %d", main_thick, GRAB))

print("✅ test_splitter_handle_grab_width.lua passed")
