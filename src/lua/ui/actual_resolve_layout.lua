-- Actual DaVinci Resolve layout based on real screenshot
print("🎬 Creating actual DaVinci Resolve layout...")

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_TITLE(main_window, "JVE Editor - Actual Resolve Layout")
qt_constants.PROPERTIES.SET_SIZE(main_window, 1600, 900)

-- Main horizontal splitter (Media Pool | Center | Inspector)
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

-- Left panel: Media Pool (narrower like in Resolve)
local media_pool = qt_constants.WIDGET.CREATE()
local media_layout = qt_constants.LAYOUT.CREATE_VBOX()
local media_title = qt_constants.WIDGET.CREATE_LABEL("Media Pool")
qt_constants.PROPERTIES.SET_STYLE(media_title, "background: #3a3a3a; color: white; padding: 4px; font-size: 12px;")
qt_constants.LAYOUT.ADD_WIDGET(media_layout, media_title)

local media_tree = qt_constants.WIDGET.CREATE_TREE()
qt_constants.LAYOUT.ADD_WIDGET(media_layout, media_tree)
qt_constants.LAYOUT.SET_ON_WIDGET(media_pool, media_layout)

-- Center area: Vertical splitter (Viewer | Timeline) 
-- But timeline should be MUCH larger than viewer
local center_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

-- Top center: Viewer (much smaller)
local viewer_panel = qt_constants.WIDGET.CREATE()
local viewer_layout = qt_constants.LAYOUT.CREATE_VBOX()
local viewer_title = qt_constants.WIDGET.CREATE_LABEL("Viewer")
qt_constants.PROPERTIES.SET_STYLE(viewer_title, "background: #3a3a3a; color: white; padding: 4px; font-size: 12px;")
qt_constants.LAYOUT.ADD_WIDGET(viewer_layout, viewer_title)

local viewer_content = qt_constants.WIDGET.CREATE_LABEL("Video Preview")
qt_constants.PROPERTIES.SET_STYLE(viewer_content, "background: black; color: #666; padding: 20px; text-align: center; font-size: 14px;")
qt_constants.LAYOUT.ADD_WIDGET(viewer_layout, viewer_content)
qt_constants.LAYOUT.SET_ON_WIDGET(viewer_panel, viewer_layout)

-- Bottom center: Timeline (much larger, like in Resolve)
local timeline_panel = qt_constants.WIDGET.CREATE()
local timeline_layout = qt_constants.LAYOUT.CREATE_VBOX()
local timeline_title = qt_constants.WIDGET.CREATE_LABEL("Timeline")
qt_constants.PROPERTIES.SET_STYLE(timeline_title, "background: #3a3a3a; color: white; padding: 4px; font-size: 12px;")
qt_constants.LAYOUT.ADD_WIDGET(timeline_layout, timeline_title)

local timeline_content = qt_constants.WIDGET.CREATE_LABEL("Timeline tracks with clips\n(ScriptableTimeline will go here)")
qt_constants.PROPERTIES.SET_STYLE(timeline_content, "background: #2a2a2a; color: #888; padding: 40px; text-align: center;")
qt_constants.LAYOUT.ADD_WIDGET(timeline_layout, timeline_content)
qt_constants.LAYOUT.SET_ON_WIDGET(timeline_panel, timeline_layout)

-- Add viewer and timeline to center splitter
qt_constants.LAYOUT.ADD_WIDGET(center_splitter, viewer_panel)
qt_constants.LAYOUT.ADD_WIDGET(center_splitter, timeline_panel)

-- Set center splitter proportions (viewer: 25%, timeline: 75% - like Resolve)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(center_splitter, {200, 600})

-- Right panel: Single combined Inspector (like Resolve)
local inspector_panel = qt_constants.WIDGET.CREATE()
local inspector_layout = qt_constants.LAYOUT.CREATE_VBOX()
local inspector_title = qt_constants.WIDGET.CREATE_LABEL("Inspector")
qt_constants.PROPERTIES.SET_STYLE(inspector_title, "background: #3a3a3a; color: white; padding: 4px; font-size: 12px;")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, inspector_title)

-- Search field
local search_field = qt_constants.WIDGET.CREATE_LINE_EDIT("Search properties...")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, search_field)

-- Property tabs area (single combined area like Resolve)
local property_content = qt_constants.WIDGET.CREATE_LABEL("Video | Audio | Color | Motion | Effects\n\nProperty controls go here\n(Volume, Pan, etc.)")
qt_constants.PROPERTIES.SET_STYLE(property_content, "background: #353535; color: #ccc; padding: 20px; font-size: 12px;")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, property_content)
qt_constants.LAYOUT.SET_ON_WIDGET(inspector_panel, inspector_layout)

-- Add all panels to main splitter
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, media_pool)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, center_splitter)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, inspector_panel)

-- Set main splitter proportions like Resolve (media: 15%, center: 65%, inspector: 20%)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {240, 1040, 320})

-- Set as central widget
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)

-- Apply Resolve-like dark theme
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
print("✅ Actual DaVinci Resolve layout created")

return main_window