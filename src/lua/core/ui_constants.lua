--- UI System Constants
-- Three-tier theme tokens (design-system convention; see docs/ui-theme-tokens.md):
--   TIER 1 PALETTE   — raw values, named by APPEARANCE (a lightness rank or hue).
--                      The only place hex literals live. Module-local; never
--                      exported, never read by call sites. A future
--                      interface-lightness slider remaps these by recomputing
--                      each GREY_<rank> from its rank — which is why the names
--                      are ranks, not pixel values (see todo-ui-lightness-slider).
--   TIER 2 SEMANTIC  — named by INTENT/ROLE (SURFACE_*, TEXT_*, BORDER_*,
--                      STATE_*, ACCENT_*). What almost every call site uses.
--   TIER 3 COMPONENT — named by WIDGET, only where a surface is genuinely
--                      special-cased and not a plain semantic role.
-- Call sites reference TIER 2/3 — never TIER 1. Re-tint edits TIER 1 values in
-- place; names and call sites never move.
local ui_constants = {}

-- =============================================================================
-- TIER 1 — PALETTE (primitives; named by appearance; the only hex literals)
-- =============================================================================
-- Neutral ramp. The number is a relative-lightness RANK (950 = darkest), NOT a
-- pixel value — it stays stable when a re-tint / lightness-slider shifts the
-- bytes. Values are blue-tinted greys measured from DaVinci Resolve (B ≈ R+6).
-- Every distinct source value is preserved as its own rung; several rungs in
-- the 860–700 band sit within 1–2 levels of each other.
-- Cool-tinted to match Resolve chrome: B = R+6, G = R (the tint measured off
-- #28282E/#24242A). Re-tint pass 2026-06-20 — values shifted, ranks unchanged.
local GREY_950 = "#09090f"   -- 9,9,15    deepest hairline
local GREY_900 = "#1a1a20"   -- 26,26,32  deepest inset surface (scrollbar track)
local GREY_860 = "#1d1d23"   -- 29,29,35  timeline track-header
local GREY_850 = "#1e1e24"   -- 30,30,36  structural canvas
local GREY_840 = "#1f1f25"   -- 31,31,37  editable field well
local GREY_830 = "#212126"   -- 33,33,38  cool list-header / breadcrumb (Resolve-measured)
local GREY_820 = "#232329"   -- 35,35,41  timeline canvas
local GREY_790 = "#25252b"   -- 37,37,43  track row (even)
local GREY_780 = "#26262c"   -- 38,38,44  field, focused
local GREY_750 = "#28282e"   -- 40,40,46  chrome base (Resolve-measured)
local GREY_730 = "#2a2a30"   -- 42,42,48  read-only field
local GREY_720 = "#2b2b31"   -- 43,43,49  raised content surface (inspector body)
local GREY_700 = "#2d2d33"   -- 45,45,51  unfocused panel border
local GREY_650 = "#333339"   -- 51,51,57  track-header button border
local GREY_600 = "#3a3a40"   -- 58,58,64  overlay surface (dropdowns, menus)
local GREY_550 = "#404046"   -- 64,64,70  structural divider
local GREY_500 = "#45454b"   -- 69,69,75  hover wash
local GREY_480 = "#4a4a50"   -- 74,74,80  scrollbar thumb
local GREY_450 = "#55555b"   -- 85,85,91  control outline
local GREY_400 = "#66666c"   -- 102,102,108 disabled fill
local COOL_860 = "#222232"   -- 34,34,50  already-cool track-header border

-- Text neutrals (near-white; kept off the grey ramp).
local INK_000 = "#ffffff"    -- pure white
local INK_050 = "#f5f5f5"    -- 245  heading
local INK_120 = "#e6e6e6"    -- 230  editable value text
local INK_140 = "#dcdcdc"    -- 220  label text
local INK_200 = "#cccccc"    -- 204  dimmer / inactive label text
local INK_460 = "#888888"    -- 136  muted / read-only text

-- Accent hues (named by hue; role lives in TIER 2).
local BLUE         = "#0a84ff"   -- macOS accent
local BLUE_DEEP    = "#0078d4"   -- focus-border blue
local BLUE_PRESSED = "#106ebe"   -- pressed/hover action blue
local CYAN         = "#5ac8fa"   -- keyboard-focus cyan
local RED          = "#e64b3d"   -- 230,75,61 selection / error
local ORANGE       = "#ff6b35"   -- section indicator

-- =============================================================================
-- TIER 2 — SEMANTIC (intent/role; what call sites use)
-- =============================================================================
-- SURFACE_* — backgrounds, ordered by elevation (deeper = recessed).
local SURFACE_WELL     = GREY_900   -- deepest inset (scrollbar track, input wells)
local SURFACE_CANVAS   = GREY_850   -- editing surfaces (timeline, ruler, monitor)
local SURFACE_CHROME   = GREY_750   -- app/panel chrome (the signature surface)
local SURFACE_PANEL    = GREY_720   -- content panel raised on chrome (inspector body)
local SURFACE_OVERLAY  = GREY_600   -- popovers, dropdowns, menus, section headers
local SURFACE_HOVER    = GREY_500   -- hover wash
local SURFACE_DISABLED = GREY_400   -- disabled fill

-- TEXT_*
local TEXT_PRIMARY   = INK_000
local TEXT_HEADING   = INK_050
local TEXT_LABEL     = INK_140
local TEXT_LABEL_DIM = INK_200   -- inactive/secondary label
local TEXT_VALUE     = INK_120   -- text inside an editable field
local TEXT_MUTED     = INK_460   -- read-only / disabled text

-- BORDER_*
local BORDER_HAIRLINE = GREY_950   -- thin field outlines
local BORDER_DIVIDER  = GREY_550   -- visible structural dividers
local BORDER_CONTROL  = GREY_450   -- input/dropdown outlines

-- STATE_* — interactive feedback.
local STATE_FOCUS      = BLUE_DEEP     -- focused panel/field border
local STATE_FOCUS_RING = CYAN          -- keyboard-nav ring
local STATE_SELECTED   = RED           -- selection border
local STATE_ERROR      = RED           -- field-error border (same hue as selection today)
local STATE_PRESSED    = BLUE_PRESSED  -- pressed/active action control

-- ACCENT_* — brand/action.
local ACCENT_ACTION  = BLUE     -- primary action ("call to action") button
local ACCENT_SECTION = ORANGE   -- collapsible-section marker

-- =============================================================================
-- TIER 3 — COMPONENT (widget-specific surfaces that aren't a plain role)
-- =============================================================================
local INSPECTOR_HEADER_BG    = SURFACE_OVERLAY
local INSPECTOR_CONTENT_BG   = SURFACE_PANEL
local FIELD_WELL_BG          = GREY_840   -- editable line-edit / spin well
local FIELD_FOCUS_BG         = GREY_780
local FIELD_READONLY_BG      = GREY_730
local BUTTON_BG              = GREY_550   -- push-button face (== divider grey)
local SCROLLBAR_THUMB        = GREY_480
local SCROLLBAR_TRACK_BG     = SURFACE_WELL
local LIST_HEADER_BG         = GREY_830   -- list/tree column-header + breadcrumb
local TRACK_HEADER_BG        = GREY_860
local TRACK_HEADER_BORDER    = COOL_860
local TRACK_BUTTON_BORDER    = GREY_650
local TRACK_ROW_EVEN         = GREY_790
local TRACK_ROW_ODD          = SURFACE_PANEL
local TIMELINE_CANVAS_BG     = GREY_820
local UNFOCUSED_PANEL_BORDER = GREY_700
local HEADER_HOVER_OVERLAY   = "rgba(255, 255, 255, 0.1)"  -- collapsible-header hover wash

-- =============================================================================
-- FONT CONSTANTS
-- =============================================================================
local DEFAULT_FONT_SIZE = "12px"
local HEADER_FONT_SIZE = "14px"
local TIMECODE_FONT_SIZE = "20px"

-- =============================================================================
-- DEBUG SYSTEM
-- =============================================================================
local DEBUG_COLORS_ENABLED = false  -- Set to false to disable debug colors

-- =============================================================================
-- EXPORTED COLOR CONSTANTS (TIER 2 + TIER 3 only — never TIER 1)
-- =============================================================================
ui_constants.COLORS = {
    -- Surfaces (by elevation)
    SURFACE_WELL = SURFACE_WELL,
    SURFACE_CANVAS = SURFACE_CANVAS,
    SURFACE_CHROME = SURFACE_CHROME,
    SURFACE_PANEL = SURFACE_PANEL,
    SURFACE_OVERLAY = SURFACE_OVERLAY,
    SURFACE_HOVER = SURFACE_HOVER,
    SURFACE_DISABLED = SURFACE_DISABLED,

    -- Text
    TEXT_PRIMARY = TEXT_PRIMARY,
    TEXT_HEADING = TEXT_HEADING,
    TEXT_LABEL = TEXT_LABEL,
    TEXT_LABEL_DIM = TEXT_LABEL_DIM,
    TEXT_VALUE = TEXT_VALUE,
    TEXT_MUTED = TEXT_MUTED,

    -- Borders
    BORDER_HAIRLINE = BORDER_HAIRLINE,
    BORDER_DIVIDER = BORDER_DIVIDER,
    BORDER_CONTROL = BORDER_CONTROL,

    -- Interactive state
    STATE_FOCUS = STATE_FOCUS,
    STATE_FOCUS_RING = STATE_FOCUS_RING,
    STATE_SELECTED = STATE_SELECTED,
    STATE_ERROR = STATE_ERROR,
    STATE_PRESSED = STATE_PRESSED,

    -- Accent
    ACCENT_ACTION = ACCENT_ACTION,
    ACCENT_SECTION = ACCENT_SECTION,

    -- Component surfaces
    INSPECTOR_HEADER_BG = INSPECTOR_HEADER_BG,
    INSPECTOR_CONTENT_BG = INSPECTOR_CONTENT_BG,
    FIELD_WELL_BG = FIELD_WELL_BG,
    FIELD_FOCUS_BG = FIELD_FOCUS_BG,
    FIELD_READONLY_BG = FIELD_READONLY_BG,
    BUTTON_BG = BUTTON_BG,
    SCROLLBAR_THUMB = SCROLLBAR_THUMB,
    SCROLLBAR_TRACK_BG = SCROLLBAR_TRACK_BG,
    LIST_HEADER_BG = LIST_HEADER_BG,
    TRACK_HEADER_BG = TRACK_HEADER_BG,
    TRACK_HEADER_BORDER = TRACK_HEADER_BORDER,
    TRACK_BUTTON_BORDER = TRACK_BUTTON_BORDER,
    TRACK_ROW_EVEN = TRACK_ROW_EVEN,
    TRACK_ROW_ODD = TRACK_ROW_ODD,
    TIMELINE_CANVAS_BG = TIMELINE_CANVAS_BG,
    UNFOCUSED_PANEL_BORDER = UNFOCUSED_PANEL_BORDER,
    HEADER_HOVER_OVERLAY = HEADER_HOVER_OVERLAY,
}

-- =============================================================================
-- FONT CONSTANTS
-- =============================================================================
ui_constants.FONTS = {
    DEFAULT_FONT_SIZE = DEFAULT_FONT_SIZE,
    HEADER_FONT_SIZE = HEADER_FONT_SIZE,
    TIMECODE_FONT_SIZE = TIMECODE_FONT_SIZE,
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

-- Main window geometry + panel-splitter persistence. Per-panel default
-- sizes live in ui/panel_layout.lua (derived from the panel topology); the
-- constants here are window-level and the project-setting key names used by
-- ui/layout.lua and core/commands/open_project.lua.
ui_constants.WINDOW = {
    DEFAULT_WIDTH = 1600,           -- first-launch window width in pixels
    DEFAULT_HEIGHT = 900,           -- first-launch window height in pixels
    MIN_VALID_DIMENSION = 100,      -- geometry with width/height below this (px) is treated as invalid and ignored
    MIN_PANEL_PX = 50,              -- a persisted panel narrower than this is degenerate → fall back to defaults
    SPLITTER_RESTORE_DELAY_MS = 50, -- let Qt compute the initial layout before applying saved splitter sizes
    -- Splitter handle thickness, in pixels, for the panel dividers. This is
    -- BOTH the visible divider width and the mouse grab target (Qt ties them
    -- together for a stylesheet-styled handle). The divider rendered ~4px and
    -- was effectively un-grabbable: the split cursor shows a couple px wider
    -- than the handle, so presses that felt on-target hit-tested onto the
    -- adjacent panel and the drag was dropped (first-drag-fails symptom). 6px
    -- keeps the target above that floor while staying visually slim.
    SPLITTER_HANDLE_GRAB_PX = 6,
    GEOMETRY_SETTING_KEY = "window_geometry",
    SPLITTER_SIZES_SETTING_KEY = "splitter_sizes",
}

-- =============================================================================
-- QT STYLE STRINGS
-- =============================================================================
ui_constants.STYLES = {
    -- Basic widget styles
    SCROLL_AREA = "QScrollArea { background: " .. SURFACE_CHROME .. "; border: none; }",
    CONTENT_WIDGET = "QWidget { background: " .. SURFACE_CHROME .. "; }",

    -- Header and label styles
    SECTION_HEADER = "QLabel { color: " .. TEXT_PRIMARY .. "; font-weight: bold; font-size: " .. HEADER_FONT_SIZE .. "; padding: 6px 8px; margin-top: 16px; background: none; border: none; }",
    FIELD_LABEL = "QLabel { color: " .. TEXT_LABEL_DIM .. "; font-size: " .. DEFAULT_FONT_SIZE .. "; font-weight: normal; background: transparent; text-align: right; min-width: 100px; max-width: 100px; }",

    -- Form field styles
    STRING_FIELD = "QLineEdit { background: " .. BUTTON_BG .. "; border: 1px solid " .. BORDER_CONTROL .. "; color: white; font-size: " .. DEFAULT_FONT_SIZE .. "; padding: 2px; max-height: 22px; }",
    DOUBLE_FIELD = "QDoubleSpinBox { background: " .. BUTTON_BG .. "; border: 1px solid " .. BORDER_CONTROL .. "; color: white; font-size: " .. DEFAULT_FONT_SIZE .. "; padding: 2px; max-height: 22px; }",
    ENUM_FIELD = "QComboBox { background: " .. BUTTON_BG .. "; border: 1px solid " .. BORDER_CONTROL .. "; color: white; font-size: " .. DEFAULT_FONT_SIZE .. "; max-height: 22px; }",
    STRING_FIELD_READONLY = "QLineEdit { background: " .. FIELD_READONLY_BG .. "; border: 1px solid " .. BORDER_CONTROL .. "; color: " .. TEXT_LABEL_DIM .. "; font-size: " .. DEFAULT_FONT_SIZE .. "; padding: 2px; max-height: 22px; }",
    STRING_FIELD_PLACEHOLDER = "Enter value...",

    -- Main window styling
    MAIN_WINDOW_TITLE_BAR = table.concat({
        -- Window and container backgrounds (no blanket QWidget rule — that kills native rendering)
        "QMainWindow { background-color: " .. SURFACE_CHROME .. "; color: " .. TEXT_PRIMARY .. "; }",
        "QSplitter { background-color: " .. SURFACE_CHROME .. "; }",
        -- Orientation-specific: a horizontal splitter's handle is a vertical
        -- bar (its WIDTH is the divider thickness); a vertical splitter's handle
        -- is a horizontal bar (its HEIGHT is the thickness). The generic
        -- ::handle rule with both width+height set the wrong axis per
        -- orientation and left a too-thin grab target. See WINDOW.SPLITTER_HANDLE_GRAB_PX.
        "QSplitter::handle:horizontal { background-color: " .. BORDER_DIVIDER .. "; width: " .. ui_constants.WINDOW.SPLITTER_HANDLE_GRAB_PX .. "px; }",
        "QSplitter::handle:vertical { background-color: " .. BORDER_DIVIDER .. "; height: " .. ui_constants.WINDOW.SPLITTER_HANDLE_GRAB_PX .. "px; }",
        -- Text controls
        "QLabel { background-color: " .. SURFACE_CHROME .. "; color: " .. TEXT_PRIMARY .. "; border: 1px solid " .. BORDER_DIVIDER .. "; padding: 8px; }",
        "QLineEdit { background-color: " .. BUTTON_BG .. "; color: " .. TEXT_PRIMARY .. "; border: 1px solid " .. BORDER_CONTROL .. "; padding: 4px; }",
        "QLineEdit:focus { border: 1px solid " .. STATE_FOCUS_RING .. "; }",
        -- Tree
        "QTreeWidget { background-color: " .. SURFACE_CHROME .. "; color: " .. TEXT_PRIMARY .. "; border: 1px solid " .. BORDER_DIVIDER .. "; }",
        -- Buttons
        "QPushButton { background-color: " .. BUTTON_BG .. "; color: " .. TEXT_PRIMARY .. "; border: 1px solid " .. BORDER_CONTROL .. "; border-radius: 3px; padding: 3px 8px; }",
        "QPushButton:focus { border: 1px solid " .. STATE_FOCUS_RING .. "; }",
        "QPushButton:hover { background-color: " .. SURFACE_HOVER .. "; }",
        -- Combobox: no stylesheet — Fusion dark palette handles rendering + highlight correctly.
        -- Menus
        "QMenuBar { background-color: " .. SURFACE_CHROME .. "; color: " .. TEXT_PRIMARY .. "; border: none; }",
        "QMenuBar::item { background: transparent; color: " .. TEXT_PRIMARY .. "; padding: 6px 12px; }",
        "QMenuBar::item:selected { background-color: " .. SURFACE_HOVER .. "; }",
        "QMenu { background-color: " .. SURFACE_CHROME .. "; color: " .. TEXT_PRIMARY .. "; border: 1px solid " .. BORDER_DIVIDER .. "; }",
        "QMenu::item:selected { background-color: " .. SURFACE_HOVER .. "; }",
        -- Scroll bars
        "QScrollBar:vertical { background-color: " .. SURFACE_CHROME .. "; width: 8px; }",
        "QScrollBar::handle:vertical { background-color: " .. BORDER_CONTROL .. "; border-radius: 4px; min-height: 20px; }",
        "QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }",
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
    -- Single floor for any track row, enforced everywhere: the interactive
    -- drag handler (chosen for grab-handle ergonomics) AND the load/persist
    -- path treat this as the minimum legal height. Heights below it (stale or
    -- corrupt records) are normalized up. timeline_panel_metrics re-exports
    -- this as M.MIN_TRACK_HEIGHT — one source of truth.
    MIN_TRACK_HEIGHT = 30,
    TRACK_HEADER_WIDTH = 220,    -- Default width of track header labels in pixels
    TRACK_HEADER_MIN_DRAG_WIDTH = 80, -- Narrowest the header column can be dragged
    DRAG_THRESHOLD = 5,          -- Pixels of movement before starting drag operation
    NOTIFY_DEBOUNCE_MS = 16,     -- Milliseconds (~60fps) for state change debouncing
    VIEWER_SEEK_DEFER_MS = 1,    -- Defer viewer decode after state listeners so timeline paints first
    EDGE_ZONE_PX = 7,            -- Pixels from boundary on each side (7px each side = 14px total edge zone)
    ROLL_ZONE_PX = 7,            -- Pixels centered on edit point that trigger roll selection/preview
    MIN_EDGE_SELECTABLE_WIDTH_PX = 17, -- Minimum element width for edge selection
    EDIT_POINT_ZONE = 4,         -- Pixels - must be close to center for edit point detection
    SPLITTER_HANDLE_HEIGHT = 7,  -- Qt default vertical splitter handle height in pixels
    DEFAULT_FPS_NUMERATOR = 30,  -- Default sequence frame rate numerator when not specified
    DEFAULT_FPS_DENOMINATOR = 1, -- Default sequence frame rate denominator when not specified
    ACTIVE_REGION_PAD_FRAMES_MULTIPLIER = 2, -- Multiplies sequence FPS to pad TimelineActiveRegion window
    MAX_RIPPLE_CONSTRAINT_RETRIES = 5, -- Maximum retry attempts for ripple constraint resolution
    -- Scroll axis lock — asymmetric trackpad hysteresis. See
    -- ui/timeline/scroll_axis_lock.lua for the full policy.
    -- Summary: horizontal is always allowed. Vertical is suppressed at
    -- the start of every gesture and is only released ("vertical_allowed")
    -- when cumulative |dy| crosses SCROLL_VERTICAL_INTENT_PX BEFORE
    -- cumulative |dx| crosses SCROLL_HORIZONTAL_COMMIT_PX. The horizontal
    -- threshold is a one-way ratchet: once cum_dx crosses it, the gesture
    -- is horizontal_only for the rest of the gesture, no exceptions. A
    -- pause of SCROLL_GESTURE_GAP_MS (wall-clock) resets the gesture.
    SCROLL_GESTURE_GAP_MS = 150,
    SCROLL_VERTICAL_INTENT_PX = 30,
    SCROLL_HORIZONTAL_COMMIT_PX = 20,
}

--- Compute zoom-to-fit viewport from content bounds.
-- Returns viewport_start, viewport_duration with symmetric padding.
-- When floor_start is given, the start won't go below it (unused padding
-- redistributes to the right so total padding is preserved).
-- @param min_start First frame of content
-- @param max_end Last frame of content (exclusive)
-- @param floor_start Optional minimum start (e.g. timecode origin)
-- @return viewport_start, viewport_duration (integer frames)
function ui_constants.compute_zoom_to_fit(min_start, max_end, floor_start)
    assert(type(min_start) == "number",
        "compute_zoom_to_fit: min_start must be number, got " .. type(min_start))
    assert(type(max_end) == "number",
        "compute_zoom_to_fit: max_end must be number, got " .. type(max_end))
    assert(max_end > min_start,
        string.format("compute_zoom_to_fit: max_end (%d) must exceed min_start (%d)", max_end, min_start))

    local content_dur = max_end - min_start
    local pad = math.floor(content_dur * ui_constants.TIMELINE.ZOOM_TO_FIT_PADDING)
    local vp_start = min_start - pad
    local vp_dur = content_dur + pad * 2
    if floor_start then
        assert(type(floor_start) == "number",
            "compute_zoom_to_fit: floor_start must be number, got " .. type(floor_start))
        if vp_start < floor_start then
            vp_start = floor_start
        end
    end
    return vp_start, vp_dur
end

-- Input constants (mirror Qt::MouseButton bitfield values)
ui_constants.INPUT = {
    MOUSE_LEFT_BUTTON = 1,    -- Qt::LeftButton
    MOUSE_RIGHT_BUTTON = 2,   -- Qt::RightButton
    MOUSE_MIDDLE_BUTTON = 4,  -- Qt::MiddleButton
}

return ui_constants
