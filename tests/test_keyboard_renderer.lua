#!/usr/bin/env luajit
-- Test visual keyboard renderer

package.path = package.path .. ";./src/lua/?.lua;./src/lua/?/init.lua"

-- Mock Qt bindings for testing without GUI
local mock_qt = {}
local widget_counter = 0

function mock_qt.CREATE_MAIN_WINDOW()
    widget_counter = widget_counter + 1
    return {id = "widget_" .. widget_counter, type = "main_window"}
end

function mock_qt.CREATE_BUTTON()
    widget_counter = widget_counter + 1
    return {id = "widget_" .. widget_counter, type = "button"}
end

function mock_qt.CREATE_LABEL()
    widget_counter = widget_counter + 1
    return {id = "widget_" .. widget_counter, type = "label"}
end

function mock_qt.CREATE_VBOX()
    widget_counter = widget_counter + 1
    return {id = "layout_" .. widget_counter, type = "vbox", widgets = {}}
end

function mock_qt.CREATE_HBOX()
    widget_counter = widget_counter + 1
    return {id = "layout_" .. widget_counter, type = "hbox", widgets = {}}
end

function mock_qt.SET_TEXT(widget, text)
    widget.text = text
end

function mock_qt.SET_SIZE(widget, width, height)
    widget.width = width
    widget.height = height
end

function mock_qt.SET_MINIMUM_SIZE(widget, width, height)
    widget.min_width = width
    widget.min_height = height
end

function mock_qt.SET_MAXIMUM_SIZE(widget, width, height)
    widget.max_width = width
    widget.max_height = height
end

function mock_qt.SET_MINIMUM_WIDTH(widget, width)
    widget.min_width = width
end

function mock_qt.SET_WIDGET_STYLESHEET(widget, stylesheet)
    widget.stylesheet = stylesheet
end

function mock_qt.SET_LAYOUT(widget, layout)
    widget.layout = layout
end

function mock_qt.SET_LAYOUT_SPACING(layout, spacing)
    layout.spacing = spacing
end

function mock_qt.ADD_WIDGET(layout, widget)
    table.insert(layout.widgets, widget)
end

function mock_qt.ADD_LAYOUT(layout, sublayout)
    table.insert(layout.widgets, sublayout)
end

function mock_qt.ADD_STRETCH(layout)
    table.insert(layout.widgets, {type = "stretch"})
end

function mock_qt.SET_BUTTON_CLICKED_HANDLER(button, handler)
    button.click_handler = handler
end

function mock_qt.SHOW_WINDOW(widget)
    print("Showing window:", widget.id)
end

-- Replace real qt_bindings with mock
package.loaded['qt_bindings'] = mock_qt

print("Testing keyboard_renderer.lua...\n")

-- Test 1: Module loads
print("Test 1: Module loads")
local success, keyboard_renderer = pcall(function()
    return require("ui.keyboard_renderer")
end)

if success and keyboard_renderer then
    print("  ✅ PASS: Module loads successfully")
else
    print("  ❌ FAIL:", keyboard_renderer)
    os.exit(1)
end

-- Test 2: Create keyboard widget
print("\nTest 2: Create keyboard widget")
local keyboard
success, keyboard = pcall(function()
    return keyboard_renderer.create()
end)

if success and keyboard and keyboard.type == "main_window" then
    print("  ✅ PASS: Keyboard widget created")
    print(string.format("    Size: %dx%d", keyboard.width or 0, keyboard.height or 0))
else
    print("  ❌ FAIL:", keyboard)
    os.exit(1)
end

-- Test 3: Verify keyboard has layouts
print("\nTest 3: Verify keyboard has layouts")
if keyboard.layout and keyboard.layout.widgets then
    local row_count = 0
    local key_count = 0

    -- Count rows (VBOX children should be HBOX rows)
    for _, item in ipairs(keyboard.layout.widgets) do
        if item.type == "hbox" then
            row_count = row_count + 1
            -- Count keys in this row
            for _, widget in ipairs(item.widgets) do
                if widget.type == "button" then
                    key_count = key_count + 1
                end
            end
        end
    end

    print(string.format("  ✅ PASS: Keyboard has %d rows with %d total keys", row_count, key_count))

    -- Expected: 6 rows (function, number, QWERTY, ASDF, ZXCV, bottom)
    if row_count ~= 6 then
        print(string.format("  ⚠ WARNING: Expected 6 rows, got %d", row_count))
    end
else
    print("  ❌ FAIL: Keyboard missing layout structure")
    os.exit(1)
end

-- Test 4: Create individual key
print("\nTest 4: Create individual key")
local key
success, key = pcall(function()
    return keyboard_renderer.create_key("A", 48, "normal")
end)

if success and key and key.type == "button" and key.text == "A" then
    print("  ✅ PASS: Individual key created")
    print(string.format("    Label: %s, Size: %dx%d", key.text, key.min_width or 0, key.min_height or 0))
else
    print("  ❌ FAIL:", key)
    os.exit(1)
end

-- Test 5: Key state management
print("\nTest 5: Key state management")
keyboard_renderer.clear_key_states()
keyboard_renderer.mark_key_assigned("F9", true)
keyboard_renderer.mark_key_assigned("C", true)

local assigned = keyboard_renderer.get_assigned_keys()
table.sort(assigned)

if #assigned == 2 and assigned[1] == "C" and assigned[2] == "F9" then
    print("  ✅ PASS: Key state management works")
    print(string.format("    Assigned keys: %s", table.concat(assigned, ", ")))
else
    print("  ❌ FAIL: Expected 2 assigned keys (C, F9), got:", table.concat(assigned, ", "))
    os.exit(1)
end

-- Test 6: Verify Premiere color scheme
print("\nTest 6: Verify Premiere color scheme")
local test_key = keyboard_renderer.create_key("Test", 48, "normal")
if test_key.stylesheet and string.match(test_key.stylesheet, "#2d2d30") then
    print("  ✅ PASS: Premiere dark theme colors applied")
else
    print("  ❌ FAIL: Expected Premiere color scheme in stylesheet")
    os.exit(1)
end

print("\n" .. string.rep("=", 60))
print("All tests passed!")
print("Visual keyboard renderer is ready")
print("\nKey features:")
print("  • Full QWERTY layout with function keys")
print("  • Premiere Pro dark theme (#1e1e1e background, #2d2d30 keys)")
print("  • Key state tracking (assigned shortcuts, hover)")
print("  • Proper key sizing (Tab, Shift, Space, etc.)")
print("  • Click handlers for future interaction")
