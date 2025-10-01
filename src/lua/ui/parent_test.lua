-- Test explicit parenting
print("🔧 Testing widget parenting...")

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_TITLE(main_window, "Parent Test")
qt_constants.PROPERTIES.SET_SIZE(main_window, 600, 400)

-- Create a central widget 
local central_widget = qt_constants.WIDGET.CREATE()

-- Create a label and add it directly without layout first
local test_label = qt_constants.WIDGET.CREATE_LABEL("DIRECT TEST - Should be visible!")
qt_constants.PROPERTIES.SET_STYLE(test_label, "background: red; color: white; font-size: 24px; padding: 20px;")

-- Set the label as the central widget directly (no layout)
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, test_label)

-- Show window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ Parent test window shown")

return main_window