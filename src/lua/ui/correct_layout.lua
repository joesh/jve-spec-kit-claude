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
local project_browser_mod = require("ui.project_browser")
local project_browser = project_browser_mod.create()

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
print("🔍 Step 1: About to create inspector container")
local inspector_panel = qt_constants.WIDGET.CREATE_INSPECTOR()
print("🔍 Step 2: Inspector container created")

-- 4. Timeline panel (create early, before inspector blocks execution)
print("📦 Loading timeline_panel module...")
local timeline_panel_mod = require("ui.timeline.timeline_panel")
print("📦 Creating timeline panel...")
local timeline_panel = timeline_panel_mod.create()
print("✅ Timeline panel created")

-- Initialize the Lua inspector content following working reference pattern
print("🔍 Creating Lua metadata inspector content...")

local view = require("ui.inspector.view")

-- First mount the view on the container
local mount_result = view.mount(inspector_panel)
if mount_result and mount_result.success then
    print("✅ Inspector view mounted")

    -- Then create the schema-driven content
    local inspector_success, inspector_result = pcall(view.create_schema_driven_inspector)

    if not inspector_success then
        print("❌ Inspector creation failed: " .. tostring(inspector_result))
    else
        print("✅ Schema-driven inspector created successfully")
    end

    -- Wire up timeline to inspector
    timeline_panel_mod.set_inspector(view)
    print("✅ Timeline wired to inspector")
else
    print("❌ Inspector mount failed: " .. tostring(mount_result))
end

-- Add three panels to top splitter
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, project_browser)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, viewer_panel)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, inspector_panel)

-- Set top splitter proportions (equal thirds)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(top_splitter, {533, 533, 534})

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