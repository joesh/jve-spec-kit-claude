require('test_env')

print("=== Test Focus Manager ===")

-----------------------------------------------------------------------
-- Mock infrastructure — tracks every Qt call for assertion
-----------------------------------------------------------------------
local calls = {}
local function record(name)
    return function(...)
        table.insert(calls, { fn = name, args = {...} })
    end
end
local function reset_calls() calls = {} end

local function find_calls(fn_name)
    local found = {}
    for _, c in ipairs(calls) do
        if c.fn == fn_name then table.insert(found, c) end
    end
    return found
end

-- Fake widget identity
local widget_id_seq = 0
local function make_widget(name)
    widget_id_seq = widget_id_seq + 1
    return { _id = widget_id_seq, _name = name or ("widget_" .. widget_id_seq) }
end

-- Track stylesheets set on widgets
local widget_stylesheets
-- Track properties set on widgets
local widget_properties

-- Mock qt_constants
local mock_qt_constants = {
    WIDGET = {
        CREATE = function()
            local w = make_widget("overlay_qwidget")
            table.insert(calls, { fn = "WIDGET.CREATE", args = {}, result = w })
            return w
        end,
        CREATE_FRAME = function()
            local w = make_widget("overlay_qframe")
            table.insert(calls, { fn = "WIDGET.CREATE_FRAME", args = {}, result = w })
            return w
        end,
        SET_PARENT = record("WIDGET.SET_PARENT"),
    },
    PROPERTIES = {
        SET_GEOMETRY = record("PROPERTIES.SET_GEOMETRY"),
        GET_SIZE = function() return 800, 600 end,
        GET_GEOMETRY = function() return 0, 0, 800, 600 end,
    },
    DISPLAY = {
        SET_VISIBLE = record("DISPLAY.SET_VISIBLE"),
        RAISE = record("DISPLAY.RAISE"),
    },
    SIGNAL = {
        SET_GEOMETRY_CHANGE_HANDLER = record("SIGNAL.SET_GEOMETRY_CHANGE_HANDLER"),
    },
}
package.loaded["core.qt_constants"] = mock_qt_constants

package.loaded["core.ui_constants"] = {
    COLORS = { FOCUS_BORDER_COLOR = "#0078d4" },
}

local active_panel_set
package.loaded["ui.selection_hub"] = {
    set_active_panel = function(panel_id) active_panel_set = panel_id end,
}

package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
    trace = function() end,
}

-- Mock globals
_G.qt_set_widget_stylesheet = function(widget, stylesheet)
    widget_stylesheets[widget] = stylesheet
    table.insert(calls, { fn = "qt_set_widget_stylesheet", args = { widget, stylesheet } })
end
_G.qt_set_widget_attribute = record("qt_set_widget_attribute")
_G.qt_set_object_name = function(widget, name)
    widget._object_name = name
    table.insert(calls, { fn = "qt_set_object_name", args = { widget, name } })
end
_G.qt_set_widget_property = function(widget, name, value)
    if not widget_properties[widget] then widget_properties[widget] = {} end
    widget_properties[widget][name] = value
    table.insert(calls, { fn = "qt_set_widget_property", args = { widget, name, value } })
end
_G.qt_set_widget_contents_margins = record("qt_set_widget_contents_margins")
_G.qt_set_focus_handler = record("qt_set_focus_handler")
_G.qt_set_focus = record("qt_set_focus")
_G.qt_update_widget = record("qt_update_widget")

-- Ensure mocks are in place
assert(type(package.loaded["core.qt_constants"]) == "table",
    "qt_constants mock must be a table")

-- Load module
package.loaded["ui.focus_manager"] = nil
local focus_manager = require("ui.focus_manager")

-----------------------------------------------------------------------
-- Setup: register panels like layout.lua does
-----------------------------------------------------------------------
local browser_widget = make_widget("browser")
local viewer_widget = make_widget("viewer")
local viewer_header = make_widget("viewer_header")
local inspector_widget = make_widget("inspector")
local timeline_widget = make_widget("timeline")

reset_calls()
widget_stylesheets = {}  -- luacheck: no unused
widget_properties = {}

focus_manager.register_panel("project_browser", browser_widget, nil, "Project Browser")
focus_manager.register_panel("viewer", viewer_widget, viewer_header, "Viewer")
focus_manager.register_panel("inspector", inspector_widget, nil, "Inspector")
focus_manager.register_panel("timeline", timeline_widget, nil, "Timeline")

-----------------------------------------------------------------------
-- INVARIANT 1: No child overlay widgets created
-- Overlay approach caused z-order bugs on macOS (native NSView occlusion).
-----------------------------------------------------------------------
print("\n  test: no child overlay widgets created...")
local parent_calls = find_calls("WIDGET.SET_PARENT")

for _, c in ipairs(parent_calls) do
    local parent = c.args[2]
    local is_panel = (parent == browser_widget or parent == viewer_widget
                      or parent == inspector_widget or parent == timeline_widget)
    assert(not is_panel,
        "REGRESSION: child widget parented to panel widget '" .. (parent._name or "?")
        .. "' — overlay approach causes z-order occlusion on macOS")
end
print("  ✓ no child overlay widgets")

-----------------------------------------------------------------------
-- INVARIANT 2: Focused panel gets focusBorderColor property set
-- Border is painted directly by StyledWidget::paintEvent from this property.
-----------------------------------------------------------------------
print("\n  test: focused panel gets border color property...")
reset_calls()
widget_properties = {}

focus_manager.set_focused_panel("project_browser")

local browser_props = widget_properties[browser_widget]
assert(browser_props, "browser widget must receive properties")
assert(browser_props.focusBorderColor == "#0078d4",
    "focused panel must get focus color, got: " .. tostring(browser_props.focusBorderColor))
print("  ✓ focused panel gets border color property")

-----------------------------------------------------------------------
-- INVARIANT 3: Unfocused panels get empty border color (no border)
-----------------------------------------------------------------------
print("\n  test: unfocused panel border cleared...")
widget_properties = {}
focus_manager.set_focused_panel("viewer")

local browser_props2 = widget_properties[browser_widget]
assert(browser_props2 and browser_props2.focusBorderColor == "#2d2d2d",
    "unfocused panel must get unfocused border color, got: " .. tostring(browser_props2 and browser_props2.focusBorderColor))
local viewer_props = widget_properties[viewer_widget]
assert(viewer_props and viewer_props.focusBorderColor == "#0078d4",
    "newly focused panel must get focus color")
print("  ✓ unfocused panel border cleared")

-----------------------------------------------------------------------
-- INVARIANT 4: No stylesheet border rules on any panel widget
-- Stylesheet borders don't render on macOS Qt6 — only property-based.
-----------------------------------------------------------------------
print("\n  test: no stylesheet border rules on panel widgets...")
widget_stylesheets = {}
widget_properties = {}
focus_manager.set_focused_panel("inspector")

-- Panel widgets should NOT receive any stylesheet with border rules
for _, w in ipairs({browser_widget, viewer_widget, inspector_widget, timeline_widget}) do
    local ss = widget_stylesheets[w]
    if ss then
        assert(not ss:find("border"), string.format(
            "REGRESSION: panel widget '%s' received stylesheet border rule — "
            .. "borders must use focusBorderColor property, not stylesheets",
            w._name))
    end
end
print("  ✓ no stylesheet border rules on panels")

-----------------------------------------------------------------------
-- INVARIANT 5: Header widget gets styled when present
-----------------------------------------------------------------------
print("\n  test: header widget styled when focused...")
widget_stylesheets = {}
widget_properties = {}
focus_manager.set_focused_panel("viewer")
local header_ss = widget_stylesheets[viewer_header]
assert(header_ss, "viewer header must receive stylesheet")
assert(header_ss:find("QLabel"),
    "header stylesheet should style QLabel")
print("  ✓ header widget styled")

-----------------------------------------------------------------------
-- INVARIANT 6: Panels without headers still get border highlight
-----------------------------------------------------------------------
print("\n  test: headerless panels get border highlight...")
widget_properties = {}
focus_manager.set_focused_panel("timeline")
local timeline_props = widget_properties[timeline_widget]
assert(timeline_props and timeline_props.focusBorderColor == "#0078d4",
    "headerless panel must get focus border color property")
print("  ✓ headerless panels get border")

-----------------------------------------------------------------------
-- INVARIANT 7: selection_hub notified on focus change
-----------------------------------------------------------------------
print("\n  test: selection_hub notified...")
active_panel_set = nil
focus_manager.set_focused_panel("project_browser")
assert(active_panel_set == "project_browser",
    "selection_hub must be notified of focus change")
print("  ✓ selection_hub notified")

-----------------------------------------------------------------------
-- INVARIANT 8: qt_set_widget_property called (not stylesheet) for borders
-- This is the KEY invariant — ensures we use the property-based rendering
-- path that actually works on macOS Qt6 with Metal.
-----------------------------------------------------------------------
print("\n  test: borders use qt_set_widget_property not stylesheets...")
reset_calls()
widget_properties = {}
widget_stylesheets = {}  -- luacheck: no unused
focus_manager.set_focused_panel("inspector")

local prop_calls = find_calls("qt_set_widget_property")
assert(#prop_calls > 0,
    "REGRESSION: must use qt_set_widget_property for focus borders")
-- Verify the property name is correct
for _, c in ipairs(prop_calls) do
    assert(c.args[2] == "focusBorderColor",
        "property name must be 'focusBorderColor', got: " .. tostring(c.args[2]))
end
print("  ✓ borders use qt_set_widget_property")

print("\n✅ test_focus_manager.lua passed")
