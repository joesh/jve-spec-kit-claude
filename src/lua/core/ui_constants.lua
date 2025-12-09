-- UI System Constants
-- Centralized constants with proper naming conventions and theme abstraction

local ui_constants = {}

-- =============================================================================
-- THEME LAYER: DaVinci Resolve Color Palette (RGB sampled values)
-- =============================================================================
-- Core DaVinci Resolve colors - these are the source theme values
local RESOLVE_PANEL_BACKGROUND_COLOR = "#28282d"    -- 40,40,45 (panel background)
local RESOLVE_FIELD_BACKGROUND_COLOR = "#1f1f1f"    -- 31,31,31 (field background)
local RESOLVE_FIELD_BORDER_COLOR = "#090909"        -- 9,9,9 (field border)
local RESOLVE_FIELD_TEXT_COLOR = "#e6e6e6"          -- 230,230,230 (editable text)
local RESOLVE_LABEL_TEXT_COLOR = "#dcdcdc"          -- 220,220,220 (labels)
local RESOLVE_HEADER_TEXT_COLOR = "#f5f5f5"         -- 245,245,245 (categories/headers)
local RESOLVE_WHITE_TEXT_COLOR = "#ffffff"          -- Pure white for headers
local RESOLVE_FOCUS_BORDER_COLOR = "#0078d4"        -- Blue focus border
local RESOLVE_SCROLL_BACKGROUND_COLOR = "#282828"   -- Scroll area background
local RESOLVE_SCROLL_BORDER_COLOR = "#404040"       -- Scroll area border
local RESOLVE_HOVER_BACKGROUND_COLOR = "#454545"    -- Hover state background
local RESOLVE_SECTION_INDICATOR_COLOR = "#ff6b35"   -- Orange section indicator
local RESOLVE_DISABLED_BACKGROUND_COLOR = "#666666" -- Disabled state background
local RESOLVE_SELECTION_BORDER_COLOR = "#e64b3d"    -- 230,75,61 (selection border)
local RESOLVE_FIELD_FOCUS_BACKGROUND_COLOR = "#262626"    -- Focus background for fields
local RESOLVE_DROPDOWN_BACKGROUND_COLOR = "#3a3a3a"       -- Dropdown background 
local RESOLVE_DROPDOWN_BORDER_COLOR = "#555555"           -- Dropdown border
local RESOLVE_BUTTON_HOVER_COLOR = "#106ebe"              -- Button hover state
local RESOLVE_READONLY_BACKGROUND_COLOR = "#2a2a2a"       -- Read-only field background
local RESOLVE_READONLY_BORDER_COLOR = "#555555"           -- Read-only field border
local RESOLVE_GENERAL_LABEL_COLOR = "#cccccc"             -- General label color

-- =============================================================================
-- ABSTRACTION LAYER: Semantic Color Names (maps to current theme)
-- =============================================================================
-- These are the names used throughout the codebase - they map to the current theme
local PANEL_BACKGROUND_COLOR = RESOLVE_PANEL_BACKGROUND_COLOR
local FIELD_BACKGROUND_COLOR = RESOLVE_FIELD_BACKGROUND_COLOR
local FIELD_BORDER_COLOR = RESOLVE_FIELD_BORDER_COLOR
local FIELD_TEXT_COLOR = RESOLVE_FIELD_TEXT_COLOR
local LABEL_TEXT_COLOR = RESOLVE_LABEL_TEXT_COLOR
local HEADER_TEXT_COLOR = RESOLVE_HEADER_TEXT_COLOR
local WHITE_TEXT_COLOR = RESOLVE_WHITE_TEXT_COLOR
local FOCUS_BORDER_COLOR = RESOLVE_FOCUS_BORDER_COLOR
local SCROLL_BACKGROUND_COLOR = RESOLVE_SCROLL_BACKGROUND_COLOR
local SCROLL_BORDER_COLOR = RESOLVE_SCROLL_BORDER_COLOR
local HOVER_BACKGROUND_COLOR = RESOLVE_HOVER_BACKGROUND_COLOR
local SECTION_INDICATOR_COLOR = RESOLVE_SECTION_INDICATOR_COLOR
local DISABLED_BACKGROUND_COLOR = RESOLVE_DISABLED_BACKGROUND_COLOR
local SELECTION_BORDER_COLOR = RESOLVE_SELECTION_BORDER_COLOR
local FIELD_FOCUS_BACKGROUND_COLOR = RESOLVE_FIELD_FOCUS_BACKGROUND_COLOR
local DROPDOWN_BACKGROUND_COLOR = RESOLVE_DROPDOWN_BACKGROUND_COLOR
local DROPDOWN_BORDER_COLOR = RESOLVE_DROPDOWN_BORDER_COLOR
local BUTTON_HOVER_COLOR = RESOLVE_BUTTON_HOVER_COLOR
local READONLY_BACKGROUND_COLOR = RESOLVE_READONLY_BACKGROUND_COLOR
local READONLY_BORDER_COLOR = RESOLVE_READONLY_BORDER_COLOR
local GENERAL_LABEL_COLOR = RESOLVE_GENERAL_LABEL_COLOR

-- Additional semantic colors
local COLLAPSIBLE_HEADER_HOVER_BACKGROUND_COLOR = "rgba(255, 255, 255, 0.1)"
local BUTTON_BACKGROUND_COLOR = SCROLL_BORDER_COLOR  -- Reuse scroll border for button background

-- =============================================================================
-- FONT CONSTANTS
-- =============================================================================
local DEFAULT_FONT_SIZE = "12px"
local HEADER_FONT_SIZE = "14px"

-- =============================================================================
-- DEBUG SYSTEM
-- =============================================================================
local DEBUG_COLORS_ENABLED = false  -- Set to false to disable debug colors

-- =============================================================================
-- EXPORTED COLOR CONSTANTS
-- =============================================================================
ui_constants.COLORS = {
    -- Panel and background colors
    PANEL_BACKGROUND_COLOR = PANEL_BACKGROUND_COLOR,
    SCROLL_BACKGROUND_COLOR = SCROLL_BACKGROUND_COLOR,
    
    -- Field colors
    FIELD_BACKGROUND_COLOR = FIELD_BACKGROUND_COLOR,
    FIELD_BORDER_COLOR = FIELD_BORDER_COLOR,
    FIELD_TEXT_COLOR = FIELD_TEXT_COLOR,
    FIELD_FOCUS_BACKGROUND_COLOR = FIELD_FOCUS_BACKGROUND_COLOR,
    
    -- Text colors
    WHITE_TEXT_COLOR = WHITE_TEXT_COLOR,
    LABEL_TEXT_COLOR = LABEL_TEXT_COLOR,
    HEADER_TEXT_COLOR = HEADER_TEXT_COLOR,
    GENERAL_LABEL_COLOR = GENERAL_LABEL_COLOR,
    
    -- Interactive colors
    FOCUS_BORDER_COLOR = FOCUS_BORDER_COLOR,
    SELECTION_BORDER_COLOR = SELECTION_BORDER_COLOR,
    HOVER_BACKGROUND_COLOR = HOVER_BACKGROUND_COLOR,
    
    -- UI element colors
    SCROLL_BORDER_COLOR = SCROLL_BORDER_COLOR,
    SECTION_INDICATOR_COLOR = SECTION_INDICATOR_COLOR,
    DISABLED_BACKGROUND_COLOR = DISABLED_BACKGROUND_COLOR,
    
    -- Form control colors
    DROPDOWN_BACKGROUND_COLOR = DROPDOWN_BACKGROUND_COLOR,
    DROPDOWN_BORDER_COLOR = DROPDOWN_BORDER_COLOR,
    BUTTON_BACKGROUND_COLOR = BUTTON_BACKGROUND_COLOR,
    BUTTON_HOVER_COLOR = BUTTON_HOVER_COLOR,
    READONLY_BACKGROUND_COLOR = READONLY_BACKGROUND_COLOR,
    READONLY_BORDER_COLOR = READONLY_BORDER_COLOR,
    
    -- Header specific colors
    COLLAPSIBLE_HEADER_HOVER_BACKGROUND_COLOR = COLLAPSIBLE_HEADER_HOVER_BACKGROUND_COLOR,
}

-- =============================================================================
-- FONT CONSTANTS
-- =============================================================================
ui_constants.FONTS = {
    DEFAULT_FONT_SIZE = DEFAULT_FONT_SIZE,
    HEADER_FONT_SIZE = HEADER_FONT_SIZE,
}

-- =============================================================================
-- LAYOUT CONSTANTS (matching C++ Inspector exactly)
-- =============================================================================
ui_constants.LAYOUT = {
    MAIN_SPACING = 0,  -- C++ line 87: layout->setSpacing(0)
    CONTENT_SPACING = 2,  -- C++ line 101: layout->setSpacing(2) 
    SECTION_SPACING = 3,  -- C++ line 276: layout->setSpacing(3)
    MAIN_MARGIN_LEFT = 4, -- C++ line 86/100: setContentsMargins(4, 4, 4, 4)
    MAIN_MARGIN_TOP = 4,
    MAIN_MARGIN_RIGHT = 4,
    MAIN_MARGIN_BOTTOM = 4,
    SECTION_MARGIN_LEFT = 4,  -- C++ line 275: setContentsMargins(4, 4, 4, 4)
    SECTION_MARGIN_TOP = 4,
    SECTION_MARGIN_RIGHT = 4,
    SECTION_MARGIN_BOTTOM = 4,
    FIELD_MARGIN_LEFT = 15,  -- C++ line 292: setContentsMargins(15, 2, 8, 2)
    FIELD_MARGIN_TOP = 2,
    FIELD_MARGIN_RIGHT = 8,
    FIELD_MARGIN_BOTTOM = 2,
    FIELD_SPACING = 12,  -- C++ line 293: setSpacing(12) - wider central gutter
    LABEL_WIDTH = 100,  -- C++ line 297-298: setMinimumWidth(100), setMaximumWidth(100)
    CONTENT_PADDING = 8,   -- Padding around content areas for breathing room
    HEADER_ELEMENT_SPACING = 4  -- Horizontal spacing between dot, triangle, and text
}

-- =============================================================================
-- QT STYLE STRINGS
-- =============================================================================
ui_constants.STYLES = {
    -- Basic widget styles
    SCROLL_AREA = "QScrollArea { background: " .. PANEL_BACKGROUND_COLOR .. "; border: none; }",
    CONTENT_WIDGET = "QWidget { background: " .. PANEL_BACKGROUND_COLOR .. "; }",
    
    -- Header and label styles
    SECTION_HEADER = "QLabel { color: " .. WHITE_TEXT_COLOR .. "; font-weight: bold; font-size: " .. HEADER_FONT_SIZE .. "; padding: 6px 8px; margin-top: 16px; background: none; border: none; }",
    FIELD_LABEL = "QLabel { color: " .. GENERAL_LABEL_COLOR .. "; font-size: " .. DEFAULT_FONT_SIZE .. "; font-weight: normal; background: transparent; text-align: right; min-width: 100px; max-width: 100px; }",
    
    -- Form field styles
    STRING_FIELD = "QLineEdit { background: " .. BUTTON_BACKGROUND_COLOR .. "; border: 1px solid " .. DROPDOWN_BORDER_COLOR .. "; color: white; font-size: " .. DEFAULT_FONT_SIZE .. "; padding: 2px; max-height: 22px; }",
    DOUBLE_FIELD = "QDoubleSpinBox { background: " .. BUTTON_BACKGROUND_COLOR .. "; border: 1px solid " .. DROPDOWN_BORDER_COLOR .. "; color: white; font-size: " .. DEFAULT_FONT_SIZE .. "; padding: 2px; max-height: 22px; }",
    ENUM_FIELD = "QComboBox { background: " .. BUTTON_BACKGROUND_COLOR .. "; border: 1px solid " .. DROPDOWN_BORDER_COLOR .. "; color: white; font-size: " .. DEFAULT_FONT_SIZE .. "; max-height: 22px; }",
    STRING_FIELD_READONLY = "QLineEdit { background: " .. READONLY_BACKGROUND_COLOR .. "; border: 1px solid " .. READONLY_BORDER_COLOR .. "; color: " .. GENERAL_LABEL_COLOR .. "; font-size: " .. DEFAULT_FONT_SIZE .. "; padding: 2px; max-height: 22px; }",
    STRING_FIELD_PLACEHOLDER = "Enter value...",

    -- Main window styling
    MAIN_WINDOW_TITLE_BAR = table.concat({
        "QMainWindow { background-color: " .. PANEL_BACKGROUND_COLOR .. "; color: " .. WHITE_TEXT_COLOR .. "; }",
        "QWidget { background-color: " .. PANEL_BACKGROUND_COLOR .. "; color: " .. WHITE_TEXT_COLOR .. "; }",
        "QLabel { background-color: " .. SCROLL_BACKGROUND_COLOR .. "; color: " .. WHITE_TEXT_COLOR .. "; border: 1px solid " .. SCROLL_BORDER_COLOR .. "; padding: 8px; }",
        "QSplitter { background-color: " .. PANEL_BACKGROUND_COLOR .. "; }",
        "QSplitter::handle { background-color: " .. SCROLL_BORDER_COLOR .. "; width: 2px; height: 2px; }",
        "QTreeWidget { background-color: " .. SCROLL_BACKGROUND_COLOR .. "; color: " .. WHITE_TEXT_COLOR .. "; border: 1px solid " .. SCROLL_BORDER_COLOR .. "; }",
        "QLineEdit { background-color: " .. BUTTON_BACKGROUND_COLOR .. "; color: " .. WHITE_TEXT_COLOR .. "; border: 1px solid " .. DROPDOWN_BORDER_COLOR .. "; padding: 4px; }",
        "QMenuBar { background-color: " .. PANEL_BACKGROUND_COLOR .. "; color: " .. WHITE_TEXT_COLOR .. "; border: none; }",
        "QMenuBar::item { background: transparent; color: " .. WHITE_TEXT_COLOR .. "; padding: 6px 12px; }",
        "QMenuBar::item:selected { background-color: " .. HOVER_BACKGROUND_COLOR .. "; }",
        "QMenu { background-color: " .. PANEL_BACKGROUND_COLOR .. "; color: " .. WHITE_TEXT_COLOR .. "; border: 1px solid " .. SCROLL_BORDER_COLOR .. "; }",
        "QMenu::item:selected { background-color: " .. HOVER_BACKGROUND_COLOR .. "; }"
    }, "\n"),
    
    -- Debug system
    DEBUG_COLORS_ENABLED = DEBUG_COLORS_ENABLED,
}

-- =============================================================================
-- WIDGET IDENTIFIERS AND METADATA
-- =============================================================================

-- Widget return value names (what to look up in return_values)
ui_constants.RETURN_NAMES = {
    SCROLL_WIDGET_NAME = "scroll_widget",
    CONTENT_WIDGET_NAME = "content_widget",
    CONTENT_LAYOUT_NAME = "content_layout",
    PANEL_NAME = "panel"
}

-- Widget types for error reporting
ui_constants.WIDGET_TYPES = {
    SCROLL_AREA = "scroll_area",
    CONTENT_WIDGET = "content_widget", 
    LAYOUT = "layout",
    INSPECTOR_PANEL = "inspector_panel"
}

-- Layout types
ui_constants.LAYOUT_TYPES = {
    VERTICAL = "vertical",
    HORIZONTAL = "horizontal",
    GRID = "grid",
    FORM = "form"
}

-- Widget IDs
ui_constants.WIDGET_IDS = {
    MAIN_TIMELINE = "main_timeline",
    TIMELINE_CONTAINER = "timeline_container",
    INSPECTOR_PANEL = "inspector_panel"
}

-- =============================================================================
-- APPLICATION CONSTANTS
-- =============================================================================

-- UI text constants
ui_constants.TEXT = {
    SECTION_MARKER = "■ "
}

-- Command parameter keys
ui_constants.PARAM_KEYS = {
    WINDOW_NAME = "window_name",
    COMPLEXITY = "complexity",
    DELIVERY_DATE = "delivery_date"
}

-- Error context keys
ui_constants.ERROR_CONTEXT = {
    OPERATION = "operation",
    COMPONENT = "component", 
    WIDGET_TYPE = "widget_type",
    STEP = "step",
    PURPOSE = "purpose"
}

-- Operation names for error tracking
ui_constants.OPERATIONS = {
    CREATE_INSPECTOR_PANEL = "create_inspector_panel",
    ADD_COLLAPSIBLE_SECTION = "add_collapsible_section",
    CREATE_STRING_FIELD = "create_string_field",
    CONFIGURE_SCROLL_AREA = "configure_scroll_area"
}

-- Component names
ui_constants.COMPONENTS = {
    INSPECTOR_PANEL = "inspector_panel",
    UI_TOOLKIT = "ui_toolkit",
    METADATA_SECTION = "metadata_section"
}

-- Logging constants
ui_constants.LOGGING = {
    DEFAULT_LEVEL = "INFO",
    COMPONENT_NAMES = {
        TIMELINE = "timeline",
        METADATA = "metadata", 
        UI = "ui",
        INSPECTOR = "inspector",
        WIDGETS = "widgets",
        ERROR_SYSTEM = "error_system",
        LOGGER = "logger"
    }
}

-- Timeline constants
ui_constants.TIMELINE = {
    ZOOM_TO_FIT_PADDING = 0.05,  -- 5% padding for zoom to fit operations
    RULER_HEIGHT = 30,           -- Height reserved for timeline ruler in pixels
    TRACK_HEIGHT = 50,           -- Default height for new tracks in pixels
    TRACK_HEADER_WIDTH = 150,    -- Width of track header labels in pixels
    DRAG_THRESHOLD = 5,          -- Pixels of movement before starting drag operation
    NOTIFY_DEBOUNCE_MS = 16,     -- Milliseconds (~60fps) for state change debouncing
    EDGE_ZONE_PX = 10,           -- Pixels from boundary center to end of left/right ripple zones
    ROLL_ZONE_PX = 7,            -- Pixels centered on edit point that trigger roll selection/preview
    EDIT_POINT_ZONE = 4,         -- Pixels - must be close to center for edit point detection
    SPLITTER_HANDLE_HEIGHT = 7,  -- Qt default vertical splitter handle height in pixels
    DEFAULT_FPS_NUMERATOR = 30,  -- Default sequence frame rate numerator when not specified
    DEFAULT_FPS_DENOMINATOR = 1, -- Default sequence frame rate denominator when not specified
    MAX_RIPPLE_CONSTRAINT_RETRIES = 5, -- Maximum retry attempts for ripple constraint resolution
}

-- Input constants (mirror Qt::MouseButton bitfield values)
ui_constants.INPUT = {
    MOUSE_LEFT_BUTTON = 1,    -- Qt::LeftButton
    MOUSE_RIGHT_BUTTON = 2,   -- Qt::RightButton
    MOUSE_MIDDLE_BUTTON = 4,  -- Qt::MiddleButton
}

return ui_constants
