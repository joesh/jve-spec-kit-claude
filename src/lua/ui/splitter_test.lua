-- Test splitter specifically
print("🔧 Testing splitter...")

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_TITLE(main_window, "Splitter Test")
qt_constants.PROPERTIES.SET_SIZE(main_window, 900, 600)

-- Create splitter
local splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

-- Create three simple widgets with bright colors
local left_widget = qt_constants.WIDGET.CREATE()
qt_constants.PROPERTIES.SET_STYLE(left_widget, "background: red;")

local left_label = qt_constants.WIDGET.CREATE_LABEL("LEFT PANEL\n\nShould be RED")
qt_constants.PROPERTIES.SET_STYLE(left_label, "background: red; color: white; font-size: 16px; padding: 20px;")

local center_widget = qt_constants.WIDGET.CREATE()
qt_constants.PROPERTIES.SET_STYLE(center_widget, "background: green;")

local center_label = qt_constants.WIDGET.CREATE_LABEL("CENTER PANEL\n\nShould be GREEN")
qt_constants.PROPERTIES.SET_STYLE(center_label, "background: green; color: white; font-size: 16px; padding: 20px;")

local right_widget = qt_constants.WIDGET.CREATE()
qt_constants.PROPERTIES.SET_STYLE(right_widget, "background: blue;")

local right_label = qt_constants.WIDGET.CREATE_LABEL("RIGHT PANEL\n\nShould be BLUE")
qt_constants.PROPERTIES.SET_STYLE(right_label, "background: blue; color: white; font-size: 16px; padding: 20px;")

-- Add labels directly to splitter (QSplitter can take widgets directly)
qt_constants.LAYOUT.ADD_WIDGET(splitter, left_label)
qt_constants.LAYOUT.ADD_WIDGET(splitter, center_label)
qt_constants.LAYOUT.ADD_WIDGET(splitter, right_label)

-- Set splitter proportions
qt_constants.LAYOUT.SET_SPLITTER_SIZES(splitter, {300, 300, 300})

-- Set splitter as central widget
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, splitter)

-- Show window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ Splitter test window shown")

return main_window