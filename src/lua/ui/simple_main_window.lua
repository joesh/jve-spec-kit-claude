-- scripts/ui/simple_main_window.lua
-- PURPOSE: Simple Lua main window creation to test LuaJIT integration

print("🎬 JVE Editor - Starting Lua window creation...")

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
print("✅ Main window created")

-- Set window properties
qt_constants.PROPERTIES.SET_TITLE(main_window, "JVE Editor - Real Lua UI")
qt_constants.PROPERTIES.SET_SIZE(main_window, 1600, 900)
print("✅ Window properties set")

-- Create main layout (horizontal splitter)
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")
print("✅ Main splitter created")

-- Create project browser panel (left)
local project_browser = qt_constants.WIDGET.CREATE()
local project_layout = qt_constants.LAYOUT.CREATE_VBOX()
local project_title = qt_constants.WIDGET.CREATE_LABEL("Project Browser")
qt_constants.PROPERTIES.SET_STYLE(project_title, "font-weight: bold; padding: 8px; background: #2a2a2a; color: white;")
qt_constants.LAYOUT.ADD_WIDGET(project_layout, project_title)

local project_tree = qt_constants.WIDGET.CREATE_TREE()
qt_constants.LAYOUT.ADD_WIDGET(project_layout, project_tree)
qt_constants.LAYOUT.SET_ON_WIDGET(project_browser, project_layout)
print("✅ Project browser created")

-- Create center panel
local center_panel = qt_constants.WIDGET.CREATE()
local center_layout = qt_constants.LAYOUT.CREATE_VBOX()
local center_title = qt_constants.WIDGET.CREATE_LABEL("Timeline Area\n(ScriptableTimeline will be integrated here)")
qt_constants.PROPERTIES.SET_STYLE(center_title, "font-size: 14px; color: #888; text-align: center; padding: 40px; background: #1e1e1e;")
qt_constants.LAYOUT.ADD_WIDGET(center_layout, center_title)
qt_constants.LAYOUT.SET_ON_WIDGET(center_panel, center_layout)
print("✅ Center panel created")

-- Create inspector panel (right)
local inspector_panel = qt_constants.WIDGET.CREATE()
local inspector_layout = qt_constants.LAYOUT.CREATE_VBOX()
local inspector_title = qt_constants.WIDGET.CREATE_LABEL("Inspector")
qt_constants.PROPERTIES.SET_STYLE(inspector_title, "font-weight: bold; padding: 8px; background: #2a2a2a; color: white;")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, inspector_title)

local search_field = qt_constants.WIDGET.CREATE_LINE_EDIT("Search properties...")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, search_field)

local property_label = qt_constants.WIDGET.CREATE_LABEL("Property Inspector\n(Resolve-style inspector)")
qt_constants.PROPERTIES.SET_STYLE(property_label, "font-size: 12px; color: #ccc; padding: 20px;")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, property_label)

qt_constants.LAYOUT.SET_ON_WIDGET(inspector_panel, inspector_layout)
print("✅ Inspector panel created")

-- Add panels to main splitter
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, project_browser)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, center_panel)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, inspector_panel)
print("✅ Panels added to splitter")

-- Set splitter proportions (25% | 50% | 25%)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {400, 800, 400})
print("✅ Splitter sizes set")

-- Set as central widget
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)
print("✅ Central widget set")

-- Apply professional dark theme styles with visible contrast
qt_constants.PROPERTIES.SET_STYLE(main_window, [[
    QMainWindow {
        background: #2b2b2b;
        color: #ffffff;
    }
    QWidget {
        background: #2b2b2b;
        color: #ffffff;
    }
    QLabel {
        background: #3a3a3a;
        color: #ffffff;
        border: 1px solid #555555;
        padding: 8px;
    }
    QSplitter {
        background: #2b2b2b;
    }
    QSplitter::handle {
        background: #555555;
        width: 3px;
        height: 3px;
    }
    QTreeWidget {
        background: #353535;
        color: #ffffff;
        border: 1px solid #555555;
        selection-background-color: #4a4a4a;
    }
    QLineEdit {
        background: #353535;
        color: #ffffff;
        border: 1px solid #555555;
        padding: 4px;
        selection-background-color: #4a4a4a;
    }
]])
print("✅ Professional dark theme applied with visible contrast")

-- Show the window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ Window shown - JVE Editor with real Lua UI ready!")

-- Force window to front and raise
qt_constants.DISPLAY.SET_VISIBLE(main_window, true)

return main_window