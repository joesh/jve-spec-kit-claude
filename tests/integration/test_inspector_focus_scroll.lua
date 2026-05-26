--- Inspector focus/scroll wiring.
---
--- Tab from the search input must not land on the scroll area itself
--- (Qt's default StrongFocus on QScrollArea would put it in the chain).
--- A focused field below the viewport must be scrolled into view via
--- the ensureWidgetVisible binding.
---
--- Runs inside ./build/bin/jve --test.

local qt_constants = require("core.qt_constants")

print("=== test_inspector_focus_scroll ===")

-- Isolated scroll area with a tall content widget so there's something
-- to scroll TO. Exercises the binding, not the full inspector.
local scroll_area = qt_constants.WIDGET.CREATE_SCROLL_AREA()
assert(scroll_area, "could not create scroll area")
local content = qt_constants.WIDGET.CREATE()
assert(content, "could not create content widget")
local content_layout = qt_constants.LAYOUT.CREATE_VBOX()
qt_constants.LAYOUT.SET_ON_WIDGET(content, content_layout)
qt_constants.LAYOUT.SET_MARGINS(content_layout, 0, 0, 0, 0)
qt_constants.LAYOUT.SET_SPACING(content_layout, 0)

-- Add many child widgets; only the last is the scroll target.
local target_widget
local NUM_ROWS = 60
local ROW_HEIGHT = 30
for i = 1, NUM_ROWS do
    local row = qt_constants.WIDGET.CREATE_LABEL("row " .. i)
    qt_constants.PROPERTIES.SET_MIN_HEIGHT(row, ROW_HEIGHT)
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, row)
    if i == NUM_ROWS then target_widget = row end
end

qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(scroll_area, content)

-- Force a small viewport — height of about 6 rows worth, so a row at
-- index 60 must scroll to be visible.
qt_constants.PROPERTIES.SET_MIN_HEIGHT(scroll_area, ROW_HEIGHT * 6)
qt_constants.GEOMETRY.SET_SIZE_POLICY(scroll_area, "Fixed", "Fixed")

-- Show in a parent container and pump events so layout settles.
local container = qt_constants.WIDGET.CREATE()
local clayout = qt_constants.LAYOUT.CREATE_VBOX()
qt_constants.LAYOUT.SET_ON_WIDGET(container, clayout)
qt_constants.LAYOUT.ADD_WIDGET(clayout, scroll_area)
qt_constants.DISPLAY.SHOW(container)
local function pump(ms)
    local target = os.clock() + (ms or 100) / 1000
    while os.clock() < target do qt_constants.CONTROL.PROCESS_EVENTS() end
end
pump(150)

-- luacheck: globals qt_get_scroll_position qt_scroll_area_ensure_widget_visible
assert(type(qt_get_scroll_position) == "function",
    "qt_get_scroll_position binding missing")
assert(type(qt_scroll_area_ensure_widget_visible) == "function",
    "qt_scroll_area_ensure_widget_visible binding missing")

local before = qt_get_scroll_position(scroll_area)
qt_scroll_area_ensure_widget_visible(scroll_area, target_widget)
pump(50)
local after = qt_get_scroll_position(scroll_area)

assert(after > before, string.format(
    "ensureWidgetVisible should have scrolled; before=%d after=%d", before, after))

-- Smoke-test that the inspector still mounts cleanly (NoFocus on the
-- scroll area is unit-tested in test_inspector_scroll_area_no_focus).
local inspector_container = qt_constants.WIDGET.CREATE()
local inspector = require("ui.inspector")
inspector.mount(inspector_container)
inspector.update_selection({}, "timeline")
pump(50)

print("✅ test_inspector_focus_scroll passed")
