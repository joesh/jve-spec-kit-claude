-- Correct layout: 3 panels across top, timeline across bottom
print("🎬 Creating correct layout...")

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_TITLE(main_window, "JVE Editor - Correct Layout")
qt_constants.PROPERTIES.SET_SIZE(main_window, 1600, 900)

-- Main vertical splitter (Top row | Timeline)
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

-- Top row: Horizontal splitter (Project Browser | Viewer | Inspector)
local top_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

-- 1. Project Browser (left)
local project_browser = qt_constants.WIDGET.CREATE()
local project_layout = qt_constants.LAYOUT.CREATE_VBOX()
local project_title = qt_constants.WIDGET.CREATE_LABEL("Project Browser")
qt_constants.PROPERTIES.SET_STYLE(project_title, "background: #3a3a3a; color: white; padding: 4px; font-size: 12px;")
qt_constants.LAYOUT.ADD_WIDGET(project_layout, project_title)

local project_tree = qt_constants.WIDGET.CREATE_TREE()
qt_constants.LAYOUT.ADD_WIDGET(project_layout, project_tree)
qt_constants.LAYOUT.SET_ON_WIDGET(project_browser, project_layout)

-- 2. Src/Timeline Viewer (center)
local viewer_panel = qt_constants.WIDGET.CREATE()
local viewer_layout = qt_constants.LAYOUT.CREATE_VBOX()
local viewer_title = qt_constants.WIDGET.CREATE_LABEL("Src/Timeline Viewer")
qt_constants.PROPERTIES.SET_STYLE(viewer_title, "background: #3a3a3a; color: white; padding: 4px; font-size: 12px;")
qt_constants.LAYOUT.ADD_WIDGET(viewer_layout, viewer_title)

local viewer_content = qt_constants.WIDGET.CREATE_LABEL("Video Preview")
qt_constants.PROPERTIES.SET_STYLE(viewer_content, "background: black; color: #666; padding: 40px; text-align: center;")
qt_constants.LAYOUT.ADD_WIDGET(viewer_layout, viewer_content)
qt_constants.LAYOUT.SET_ON_WIDGET(viewer_panel, viewer_layout)

-- 3. Inspector (right) - Create container for Lua inspector
local inspector_panel = qt_constants.WIDGET.CREATE_INSPECTOR()

-- Initialize the Lua inspector system in the container
print("🔧 Attempting to initialize Lua inspector system...")

local success, result = pcall(function()
    print("🔧 Loading inspector view module...")
    local view = require("src.lua.ui.inspector.view")
    
    print("🔧 Loading inspector adapter module...")
    local adapter = require("src.lua.ui.inspector.adapter")
    
    print("🔧 Mounting view onto container widget...")
    local mount_result = view.mount(inspector_panel)
    
    if mount_result and mount_result.success then
        print("✅ Lua inspector view mounted successfully")
        
        print("🔧 Creating search UI...")
        local search_result = view.ensure_search_row()
        
        if search_result and search_result.success then
            print("✅ Inspector search row created")
        else
            print("⚠️ Inspector search row creation failed: " .. tostring(search_result))
        end
        
        return view
    else
        print("⚠️ Lua inspector mount failed: " .. tostring(mount_result))
        return nil
    end
end)

if not success then
    print("❌ Failed to initialize Lua inspector system:")
    print("   Error: " .. tostring(result))
    print("   This is expected - inspector will show as empty container")
else
    print("✅ Lua inspector system initialized successfully")
end

-- Add three panels to top splitter
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, project_browser)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, viewer_panel)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, inspector_panel)

-- Set top splitter proportions (equal thirds)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(top_splitter, {533, 533, 534})

-- Timeline panel (bottom, full width) - Use existing TimelinePanel
local timeline_panel = qt_constants.WIDGET.CREATE_TIMELINE()

-- Add top row and timeline to main splitter
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, top_splitter)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, timeline_panel)

-- Set main splitter proportions (top: 50%, timeline: 50%)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {450, 450})

-- Set as central widget
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)

-- Apply dark theme
qt_constants.PROPERTIES.SET_STYLE(main_window, [[
    QMainWindow { background: #2b2b2b; }
    QWidget { background: #2b2b2b; color: white; }
    QLabel { background: #3a3a3a; color: white; border: 1px solid #555; padding: 8px; }
    QSplitter { background: #2b2b2b; }
    QSplitter::handle { background: #555; width: 2px; height: 2px; }
    QTreeWidget { background: #353535; color: white; border: 1px solid #555; }
    QLineEdit { background: #353535; color: white; border: 1px solid #555; padding: 4px; }
]])

-- Show window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ Correct layout created: 3 panels top, timeline bottom")

return main_window