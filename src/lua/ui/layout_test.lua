-- Test layout system step by step
print("🔧 Testing layout system...")

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_TITLE(main_window, "Layout Test")
qt_constants.PROPERTIES.SET_SIZE(main_window, 800, 600)

-- Step 1: Create a central widget
local central_widget = qt_constants.WIDGET.CREATE()
qt_constants.PROPERTIES.SET_STYLE(central_widget, "background: blue;")

-- Step 2: Create a layout for the central widget
local main_layout = qt_constants.LAYOUT.CREATE_VBOX()

-- Step 3: Create a visible label
local test_label = qt_constants.WIDGET.CREATE_LABEL("LAYOUT TEST\nThis should be visible in a blue background")
qt_constants.PROPERTIES.SET_STYLE(test_label, "background: yellow; color: black; font-size: 18px; padding: 20px; border: 2px solid red;")

-- Step 4: Add label to layout
qt_constants.LAYOUT.ADD_WIDGET(main_layout, test_label)

-- Step 5: Set layout on central widget
qt_constants.LAYOUT.SET_ON_WIDGET(central_widget, main_layout)

-- Step 6: Set central widget on main window
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, central_widget)

-- Show window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ Layout test window shown")

return main_window