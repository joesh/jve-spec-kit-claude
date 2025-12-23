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
-- Size: ~196 LOC
-- Volatility: unknown
--
-- @file focus_manager.lua
-- Original intent (unreviewed):
-- - Focus Manager Module
-- - Tracks which panel has keyboard focus and provides clear visual feedback
-- - Shows a bright colored header/border on the active panel
local qt_constants = require("core.qt_constants")
local ui_constants = require("core.ui_constants")
local selection_hub = require("ui.selection_hub")

local M = {}
local logger = require("core.logger")

-- Panel registry: maps panel_id -> {widget, header_widget, panel_name}
local registered_panels = {}

local focus_debug_enabled = os.getenv("JVE_DEBUG_FOCUS") == "1"

local function focus_debug(message)
    if focus_debug_enabled then
        logger.debug("focus", message)
    end
end

-- Currently focused panel ID
local focused_panel_id = nil

-- Focus indicator colors
local FOCUS_COLOR = ui_constants.COLORS.FOCUS_BORDER_COLOR or "#0078d4"

local COLORS = {
    focused_header = FOCUS_COLOR,
    unfocused_header = "#2a2a2a",
    focused_border = FOCUS_COLOR,
    unfocused_border = "#2d2d2d",
}

local BORDER_RADIUS = 6
local BORDER_WIDTH = 2

local function sanitize_panel_id(panel_id)
    return tostring(panel_id or ""):gsub("[^%w_]", "_")
end

local function safe_set_stylesheet(widget, stylesheet, context)
    if not widget or not stylesheet then
        return
    end
    local ok, err = pcall(qt_set_widget_stylesheet, widget, stylesheet)
    if not ok then
        local suffix = context and (" (" .. context .. ")") or ""
        logger.warn("focus", string.format("Failed to set stylesheet%s: %s", suffix, tostring(err)))
    end
end

-- Register a panel for focus tracking
-- Args:
--   panel_id (string) - unique identifier
--   widget (userdata) - main panel container
--   header_widget (userdata|nil) - optional header label to recolor
--   panel_name (string|nil) - friendly name for logs
--   options (table|nil):
--       focus_widgets: array of widgets that should trigger focus highlights (defaults to {widget})
function M.register_panel(panel_id, widget, header_widget, panel_name, options)
    if not panel_id or not widget then
        logger.warn("focus", "register_panel called with missing panel_id or widget")
        return false
    end
    options = options or {}

    local sanitized_id = sanitize_panel_id(panel_id)
    local focus_widgets = {}
    if type(options.focus_widgets) == "table" then
        for _, w in ipairs(options.focus_widgets) do
            if w then
                table.insert(focus_widgets, w)
            end
        end
    end
    if #focus_widgets == 0 then
        table.insert(focus_widgets, widget)
    end

    local object_name = "focus_panel_" .. sanitized_id
    if qt_set_object_name then
        pcall(qt_set_object_name, widget, object_name)
    end
    if qt_set_widget_attribute then
        pcall(qt_set_widget_attribute, widget, "WA_StyledBackground", true)
    end

    local highlight_widget = qt_constants.WIDGET.CREATE()
    qt_constants.WIDGET.SET_PARENT(highlight_widget, widget)
    qt_constants.PROPERTIES.SET_GEOMETRY(highlight_widget, 0, 0, 1, 1)
    qt_constants.DISPLAY.SET_VISIBLE(highlight_widget, false)
    if qt_set_widget_attribute then
        pcall(qt_set_widget_attribute, highlight_widget, "WA_TransparentForMouseEvents", true)
        pcall(qt_set_widget_attribute, highlight_widget, "WA_StyledBackground", true)
    end

    registered_panels[panel_id] = {
        widget = widget,
        header_widget = header_widget,
        panel_name = panel_name or panel_id,
        focus_widgets = focus_widgets,
        object_name = object_name,
        highlight_widget = highlight_widget,
    }

    -- Install focus event handlers for all focusable widgets associated with this panel
    for index, focus_widget in ipairs(focus_widgets) do
        if focus_widget then
            local handler_name = string.format("focus_handler_%s_%d", sanitized_id, index)
            _G[handler_name] = function(event)
                M.handle_focus_event(panel_id, event)
            end
            qt_set_focus_handler(focus_widget, handler_name)
        end
    end

    -- Apply initial unfocused style
    M.update_panel_visual(panel_id, false)

    focus_debug(string.format("Focus tracking registered for panel: %s", panel_name or panel_id))
    return true
end

-- Handle focus events from Qt
function M.handle_focus_event(panel_id, event)
    if event.focus_in then
        M.set_focused_panel(panel_id)
    end
end

-- Set which panel is focused (and update visual indicators)
function M.set_focused_panel(panel_id)
    if focused_panel_id == panel_id then
        return  -- No change
    end

    -- Remove focus indicator from old panel
    if focused_panel_id then
        M.update_panel_visual(focused_panel_id, false)
    end

    -- Set new focused panel
    focused_panel_id = panel_id

    -- Add focus indicator to new panel
    if focused_panel_id then
        M.update_panel_visual(focused_panel_id, true)
        local panel = registered_panels[focused_panel_id]
        if panel then
            focus_debug(string.format("Focus: %s", panel.panel_name))
        end
    end

    selection_hub.set_active_panel(focused_panel_id)
end

-- Update visual indicators for a panel
function M.update_panel_visual(panel_id, is_focused)
    local panel = registered_panels[panel_id]
    if not panel then
        return
    end

    local border_color = is_focused and COLORS.focused_border or COLORS.unfocused_border

    if panel.header_widget then
        local header_color = is_focused and COLORS.focused_header or COLORS.unfocused_header
        safe_set_stylesheet(panel.header_widget, string.format([[ 
            QLabel {
                background: %s;
                color: white;
                padding: 4px;
                font-size: 12px;
                border: none;
            }
        ]], header_color), panel_id .. ":header")
    end

    if panel.highlight_widget then
        if qt_update_widget then
            pcall(qt_update_widget, panel.widget)
        end
        local width, height = qt_constants.PROPERTIES.GET_SIZE(panel.widget)
        if width and height then
            qt_constants.PROPERTIES.SET_GEOMETRY(panel.highlight_widget, 0, 0, width, height)
        else
            local geo_ok, _, _, w, h = pcall(qt_constants.PROPERTIES.GET_GEOMETRY, panel.widget)
            if geo_ok then
                qt_constants.PROPERTIES.SET_GEOMETRY(panel.highlight_widget, 0, 0, w or 0, h or 0)
            end
        end

        local highlight_style = string.format([[ 
            QWidget {
                border: %dpx solid %s;
                border-radius: %dpx;
                background-color: rgba(0, 0, 0, 0);
            }
        ]], BORDER_WIDTH, border_color, BORDER_RADIUS)
        safe_set_stylesheet(panel.highlight_widget, highlight_style, panel_id .. ":highlight")
        qt_constants.DISPLAY.SET_VISIBLE(panel.highlight_widget, is_focused)
        qt_constants.DISPLAY.RAISE(panel.highlight_widget)
    end
end

-- Get currently focused panel ID
function M.get_focused_panel()
    return focused_panel_id
end

function M.refresh_highlight(panel_id)
    local target = panel_id or focused_panel_id
    if not target then
        return
    end
    local is_focused = (target == focused_panel_id)
    M.update_panel_visual(target, is_focused)
end

function M.refresh_all_highlights()
    for panel_id, _ in pairs(registered_panels) do
        local is_focused = (panel_id == focused_panel_id)
        M.update_panel_visual(panel_id, is_focused)
    end
end

-- Get focused panel info
function M.get_focused_panel_info()
    if not focused_panel_id then
        return nil
    end
    return registered_panels[focused_panel_id]
end

-- Manually set focus to a specific panel (programmatic)
function M.focus_panel(panel_id)
    local panel = registered_panels[panel_id]
    if not panel then
        logger.warn("focus", string.format("focus_panel called with unknown panel %s", tostring(panel_id)))
        return false
    end

    -- Prefer the first declared focus widget (e.g., the tree inside the panel)
    local target_widget = panel.widget
    if panel.focus_widgets and panel.focus_widgets[1] then
        target_widget = panel.focus_widgets[1]
    end

    -- Qt will trigger the focus event which will call our handler
    qt_set_focus(target_widget)
    return true
end

-- Initialize all registered panels to unfocused state
function M.initialize_all_panels()
    for panel_id, _ in pairs(registered_panels) do
        M.update_panel_visual(panel_id, false)
    end
end

return M
