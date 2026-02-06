--- Focus Manager Module
-- Tracks which panel has keyboard focus and provides clear visual feedback.
--
-- Border highlights are painted directly by StyledWidget::paintEvent via the
-- "focusBorderColor" dynamic property (qt_set_widget_property). This bypasses
-- Qt stylesheet border resolution entirely — which is unreliable on macOS Qt6.
--
-- No child overlay widgets (they become native NSViews on macOS, occluding Metal).
-- No stylesheet border rules (they either don't render or cascade into children).
--
-- @file focus_manager.lua
local ui_constants = require("core.ui_constants")
local selection_hub = require("ui.selection_hub")

local M = {}
local logger = require("core.logger")

-- Panel registry: maps panel_id -> {widget, header_widget, panel_name, ...}
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
local FOCUS_COLOR = assert(ui_constants.COLORS.FOCUS_BORDER_COLOR, "focus_manager: ui_constants.COLORS.FOCUS_BORDER_COLOR is not defined")

local COLORS = {
    focused_header = FOCUS_COLOR,
    unfocused_header = "#2a2a2a",
    focused_border = FOCUS_COLOR,
    unfocused_border = "#2d2d2d",  -- subtle dark border, always drawn
}

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

--- Set the border color property on a panel's widget.
-- StyledWidget::paintEvent reads "focusBorderColor" and draws directly with QPainter.
local function apply_border_color(panel, is_focused)
    if not panel or not panel.widget then return end
    local color = is_focused and COLORS.focused_border or COLORS.unfocused_border
    local ok, err = pcall(qt_set_widget_property, panel.widget, "focusBorderColor", color)
    if not ok then
        logger.warn("focus", string.format(
            "Failed to set focusBorderColor on %s: %s", panel.panel_name, tostring(err)))
    end
end

--- Apply border colors to all registered panels based on current focus state.
local function apply_all_borders()
    for _, panel in pairs(registered_panels) do
        apply_border_color(panel, panel.panel_id == focused_panel_id)
    end
end

-- Register a panel for focus tracking
-- Args:
--   panel_id (string) - unique identifier
--   widget (userdata) - main panel container (must be StyledWidget for borders)
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

    if qt_set_widget_attribute then
        pcall(qt_set_widget_attribute, widget, "WA_StyledBackground", true)
    end

    -- Reserve space for the border so children don't paint over it
    if qt_set_widget_contents_margins then
        pcall(qt_set_widget_contents_margins, widget, BORDER_WIDTH, BORDER_WIDTH, BORDER_WIDTH, BORDER_WIDTH)
    end

    registered_panels[panel_id] = {
        widget = widget,
        header_widget = header_widget,
        panel_name = panel_name or panel_id,
        panel_id = panel_id,
        focus_widgets = focus_widgets,
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

    local old_panel_id = focused_panel_id
    focused_panel_id = panel_id

    -- Update header on old panel
    if old_panel_id then
        M.update_header(old_panel_id, false)
        local old_panel = registered_panels[old_panel_id]
        apply_border_color(old_panel, false)
    end

    -- Update header + border on new panel
    if focused_panel_id then
        M.update_header(focused_panel_id, true)
        local new_panel = registered_panels[focused_panel_id]
        apply_border_color(new_panel, true)
        if new_panel then
            focus_debug(string.format("Focus: %s", new_panel.panel_name))
        end
    end

    selection_hub.set_active_panel(focused_panel_id)
end

-- Update header visual for a single panel
function M.update_header(panel_id, is_focused)
    local panel = registered_panels[panel_id]
    if not panel or not panel.header_widget then
        return
    end
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

-- Legacy API: update visual for a single panel (headers + border)
function M.update_panel_visual(panel_id, is_focused)
    M.update_header(panel_id, is_focused)
    local panel = registered_panels[panel_id]
    apply_border_color(panel, is_focused)
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
        M.update_header(panel_id, panel_id == focused_panel_id)
    end
    apply_all_borders()
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
        M.update_header(panel_id, false)
    end
    apply_all_borders()
end

return M
