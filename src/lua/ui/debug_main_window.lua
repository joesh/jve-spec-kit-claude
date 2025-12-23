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
-- Size: ~34 LOC
-- Volatility: unknown
--
-- @file debug_main_window.lua
-- Original intent (unreviewed):
-- Debug version with bright visible content
print("🎬 JVE Editor - Creating DEBUG window with bright colors...")

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_TITLE(main_window, "JVE Editor - DEBUG VERSION")
qt_constants.PROPERTIES.SET_SIZE(main_window, 1600, 900)

-- Create main splitter
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

-- Project browser (left) - BRIGHT GREEN
local project_browser = qt_constants.WIDGET.CREATE()
local project_layout = qt_constants.LAYOUT.CREATE_VBOX()
local project_title = qt_constants.WIDGET.CREATE_LABEL("PROJECT BROWSER\n\nThis should be BRIGHT GREEN")
qt_constants.PROPERTIES.SET_STYLE(project_title, "background: lime; color: black; font-size: 16px; padding: 20px; border: 3px solid red;")
qt_constants.LAYOUT.ADD_WIDGET(project_layout, project_title)
qt_constants.LAYOUT.SET_ON_WIDGET(project_browser, project_layout)

-- Center panel - BRIGHT BLUE  
local center_panel = qt_constants.WIDGET.CREATE()
local center_layout = qt_constants.LAYOUT.CREATE_VBOX()
local center_title = qt_constants.WIDGET.CREATE_LABEL("TIMELINE AREA\n\nThis should be BRIGHT BLUE\n\nScriptableTimeline will be integrated here")
qt_constants.PROPERTIES.SET_STYLE(center_title, "background: cyan; color: black; font-size: 18px; padding: 40px; border: 3px solid red;")
qt_constants.LAYOUT.ADD_WIDGET(center_layout, center_title)
qt_constants.LAYOUT.SET_ON_WIDGET(center_panel, center_layout)

-- Inspector panel (right) - BRIGHT YELLOW
local inspector_panel = qt_constants.WIDGET.CREATE()
local inspector_layout = qt_constants.LAYOUT.CREATE_VBOX()
local inspector_title = qt_constants.WIDGET.CREATE_LABEL("INSPECTOR PANEL\n\nThis should be BRIGHT YELLOW")
qt_constants.PROPERTIES.SET_STYLE(inspector_title, "background: yellow; color: black; font-size: 16px; padding: 20px; border: 3px solid red;")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, inspector_title)

local search_field = qt_constants.WIDGET.CREATE_LINE_EDIT("Search should be VISIBLE...")
qt_constants.PROPERTIES.SET_STYLE(search_field, "background: white; color: black; font-size: 14px; padding: 8px; border: 2px solid red;")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, search_field)

qt_constants.LAYOUT.SET_ON_WIDGET(inspector_panel, inspector_layout)

-- Add to splitter
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, project_browser)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, center_panel)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, inspector_panel)

-- Set splitter sizes
qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {400, 800, 400})

-- Set as central widget
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)

-- Show the window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ DEBUG Window shown - should have BRIGHT colors!")

return main_window