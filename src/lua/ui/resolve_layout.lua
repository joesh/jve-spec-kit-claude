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
-- Size: ~63 LOC
-- Volatility: unknown
--
-- @file resolve_layout.lua
-- Original intent (unreviewed):
-- Proper DaVinci Resolve 4-panel layout
print("🎬 Creating proper DaVinci Resolve layout...")

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_TITLE(main_window, "JVE Editor - DaVinci Resolve Layout")
qt_constants.PROPERTIES.SET_SIZE(main_window, 1600, 900)

-- Main horizontal splitter (Media Pool | Center | Inspector)
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

-- Left panel: Media Pool
local media_pool = qt_constants.WIDGET.CREATE()
local media_layout = qt_constants.LAYOUT.CREATE_VBOX()
local media_title = qt_constants.WIDGET.CREATE_LABEL("Media Pool")
qt_constants.PROPERTIES.SET_STYLE(media_title, "background: #3a3a3a; color: white; padding: 8px; border: 1px solid #555;")
qt_constants.LAYOUT.ADD_WIDGET(media_layout, media_title)

local media_tree = qt_constants.WIDGET.CREATE_TREE()
qt_constants.LAYOUT.ADD_WIDGET(media_layout, media_tree)
qt_constants.LAYOUT.SET_ON_WIDGET(media_pool, media_layout)

-- Center area: Vertical splitter (Viewer | Timeline)
local center_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

-- Top center: Viewer
local viewer_panel = qt_constants.WIDGET.CREATE()
local viewer_layout = qt_constants.LAYOUT.CREATE_VBOX()
local viewer_title = qt_constants.WIDGET.CREATE_LABEL("Viewer")
qt_constants.PROPERTIES.SET_STYLE(viewer_title, "background: #3a3a3a; color: white; padding: 8px; border: 1px solid #555;")
qt_constants.LAYOUT.ADD_WIDGET(viewer_layout, viewer_title)

local viewer_content = qt_constants.WIDGET.CREATE_LABEL("Video Preview Area\n(Black video canvas)")
qt_constants.PROPERTIES.SET_STYLE(viewer_content, "background: black; color: #666; padding: 40px; text-align: center;")
qt_constants.LAYOUT.ADD_WIDGET(viewer_layout, viewer_content)
qt_constants.LAYOUT.SET_ON_WIDGET(viewer_panel, viewer_layout)

-- Bottom center: Timeline
local timeline_panel = qt_constants.WIDGET.CREATE()
local timeline_layout = qt_constants.LAYOUT.CREATE_VBOX()
local timeline_title = qt_constants.WIDGET.CREATE_LABEL("Timeline")
qt_constants.PROPERTIES.SET_STYLE(timeline_title, "background: #3a3a3a; color: white; padding: 8px; border: 1px solid #555;")
qt_constants.LAYOUT.ADD_WIDGET(timeline_layout, timeline_title)

local timeline_content = qt_constants.WIDGET.CREATE_LABEL("Timeline Area\n(ScriptableTimeline integration)")
qt_constants.PROPERTIES.SET_STYLE(timeline_content, "background: #2a2a2a; color: #888; padding: 20px; text-align: center;")
qt_constants.LAYOUT.ADD_WIDGET(timeline_layout, timeline_content)
qt_constants.LAYOUT.SET_ON_WIDGET(timeline_panel, timeline_layout)

-- Add viewer and timeline to center splitter
qt_constants.LAYOUT.ADD_WIDGET(center_splitter, viewer_panel)
qt_constants.LAYOUT.ADD_WIDGET(center_splitter, timeline_panel)

-- Set center splitter proportions (viewer: 60%, timeline: 40%)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(center_splitter, {360, 240})

-- Right panel: Inspector
local inspector_panel = qt_constants.WIDGET.CREATE()
local inspector_layout = qt_constants.LAYOUT.CREATE_VBOX()
local inspector_title = qt_constants.WIDGET.CREATE_LABEL("Inspector")
qt_constants.PROPERTIES.SET_STYLE(inspector_title, "background: #3a3a3a; color: white; padding: 8px; border: 1px solid #555;")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, inspector_title)

local search_field = qt_constants.WIDGET.CREATE_LINE_EDIT("Search properties...")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, search_field)

local inspector_content = qt_constants.WIDGET.CREATE_LABEL("Property Inspector\nVideo/Audio/Color/Motion tabs")
qt_constants.PROPERTIES.SET_STYLE(inspector_content, "background: #353535; color: #ccc; padding: 20px;")
qt_constants.LAYOUT.ADD_WIDGET(inspector_layout, inspector_content)
qt_constants.LAYOUT.SET_ON_WIDGET(inspector_panel, inspector_layout)

-- Add all panels to main splitter
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, media_pool)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, center_splitter)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, inspector_panel)

-- Set main splitter proportions (media: 20%, center: 60%, inspector: 20%)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {320, 960, 320})

-- Set as central widget
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)

-- Apply dark theme
qt_constants.PROPERTIES.SET_STYLE(main_window, [[
    QMainWindow { background: #2b2b2b; }
    QWidget { background: #2b2b2b; color: white; }
    QLabel { background: #3a3a3a; color: white; border: 1px solid #555; padding: 8px; }
    QSplitter { background: #2b2b2b; }
    QSplitter::handle { background: #555; width: 3px; height: 3px; }
    QTreeWidget { background: #353535; color: white; border: 1px solid #555; }
    QLineEdit { background: #353535; color: white; border: 1px solid #555; padding: 4px; }
]])

-- Show window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ DaVinci Resolve 4-panel layout created")

return main_window