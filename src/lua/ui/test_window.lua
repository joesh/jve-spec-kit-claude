--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~17 LOC
-- Volatility: unknown
--
-- @file test_window.lua
-- Original intent (unreviewed):
-- Minimal test window to debug black screen issue
print("🔧 Creating minimal test window...")

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
print("✅ Main window created")

-- Set basic properties
qt_constants.PROPERTIES.SET_TITLE(main_window, "Test Window - Should Be Visible")
qt_constants.PROPERTIES.SET_SIZE(main_window, 800, 600)
print("✅ Window properties set")

-- Create a simple white widget with text
local central_widget = qt_constants.WIDGET.CREATE()
local layout = qt_constants.LAYOUT.CREATE_VBOX()

-- Add a visible label
local test_label = qt_constants.WIDGET.CREATE_LABEL("🎬 TEST: This should be visible!\n\nIf you can see this text, the Lua UI is working!")
qt_constants.PROPERTIES.SET_STYLE(test_label, "background: white; color: black; font-size: 24px; padding: 50px; border: 2px solid red;")

qt_constants.LAYOUT.ADD_WIDGET(layout, test_label)
qt_constants.LAYOUT.SET_ON_WIDGET(central_widget, layout)
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, central_widget)

print("✅ Simple layout created with visible text")

-- Show the window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ Window shown")

return main_window