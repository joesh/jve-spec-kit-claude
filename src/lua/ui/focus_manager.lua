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
local log = require("core.logger").for_area("ui")

-- Panel registry: maps panel_id -> {widget, header_widget, panel_name, ...}
local registered_panels = {}


-- Currently focused panel ID
local focused_panel_id = nil

-- Focus change callbacks: called with (old_panel_id, new_panel_id)
local focus_change_callbacks = {}

-- Focus indicator colors
local FOCUS_COLOR = assert(ui_constants.COLORS.STATE_FOCUS, "focus_manager: ui_constants.COLORS.STATE_FOCUS is not defined")

-- Unfocused header uses Resolve's blue-tinted panel grey (#28282d, 40,40,45),
-- NOT a neutral grey: Resolve's chrome is cool-tinted (B ≈ R+5), and a neutral
-- #2a2a2a reads visibly different side-by-side. Match the shared constant.
local COLORS = {
    focused_header = FOCUS_COLOR,
    unfocused_header = ui_constants.COLORS.SURFACE_CHROME_RECESSED,
    focused_border = FOCUS_COLOR,
    unfocused_border = ui_constants.COLORS.UNFOCUSED_PANEL_BORDER,  -- subtle dark border, always drawn
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
        log.warn("Failed to set stylesheet%s: %s", suffix, tostring(err))
    end
end

--- Set the border color property on a panel's widget.
-- StyledWidget::paintEvent reads "focusBorderColor" and draws directly with QPainter.
local function apply_border_color(panel, is_focused)
    if not panel or not panel.widget then return end
    local color = is_focused and COLORS.focused_border or COLORS.unfocused_border
    local ok, err = pcall(qt_set_widget_property, panel.widget, "focusBorderColor", color)
    if not ok then
        log.warn("Failed to set focusBorderColor on %s: %s", panel.panel_name, tostring(err))
    end
end

--- Apply border colors to all registered panels based on current focus state.
local function apply_all_borders()
    for _, panel in pairs(registered_panels) do
        apply_border_color(panel, panel.panel_id == focused_panel_id)
    end
end

-- Install the global click-to-focus event filter. Call once at startup.
function M.install_click_to_focus()
    if not _G.qt_install_panel_focus_filter then return end

    -- Global handler: C++ calls this with the panel widget on any click.
    -- C++ passes panel_id string directly (avoids userdata identity mismatch).
    --
    -- Two regimes, distinguished by whether focus was inside the main window
    -- before this click:
    --
    -- * Within-main-window click: Qt's native click-to-focus will move focus
    --   to the clicked widget (QLineEdit, QCheckBox, etc.) via its own
    --   mousePressEvent. Calling qt_set_focus on focus_widgets[1] here would
    --   steal focus away from the click target — which is exactly what Joe
    --   reported in the Inspector: clicking a field landed focus on the
    --   scroll_area, so keystrokes went to the application shortcut dispatcher
    --   instead of the field. Skip the Qt steal; update visual state only.
    --
    -- * Cross-window click (focus was in a floating tool window like history):
    --   Qt's native click-to-focus is unreliable here — activateWindow races,
    --   focus may not transfer. The steal is required to land focus inside
    --   the main window. This is the regime commit 29597a85 was fixing.
    _G._panel_click_focus_handler = function(panel_id)
        if not (panel_id and registered_panels[panel_id]) then return end
        -- luacheck: globals qt_focus_outside_main_window
        local cross_window = qt_focus_outside_main_window and qt_focus_outside_main_window()
        if cross_window then
            M.focus_panel(panel_id)        -- steal Qt focus, update visual
        else
            M.set_focused_panel(panel_id)  -- update visual only; let Qt handle focus
        end
    end
    _G.qt_install_panel_focus_filter("_panel_click_focus_handler")
    log.event("Global click-to-focus filter installed")
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
        log.warn("register_panel called with missing panel_id or widget")
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

    -- Register with global click-to-focus filter (catches clicks on any child)
    if _G.qt_register_panel_focus_widget then
        pcall(_G.qt_register_panel_focus_widget, widget, panel_id)
    end

    -- Note: no panel-level Tab event filter. Tab is handled by Qt's
    -- QWidget::event() → focusNextPrevChild *before* events bubble to
    -- parent widgets, so a panel event filter never sees Tab. Tab
    -- containment is enforced at the application-level dispatcher
    -- (keyboard_shortcuts.lua) which calls qt_cycle_panel_focus with
    -- the panel widget looked up via focus_panel_widget() below.

    log.detail("Focus tracking registered for panel: %s", panel_name or panel_id)
    return true
end

--- Return the Qt container widget for a registered panel, or nil if unknown.
--- Used by the Tab dispatcher to bound focus cycling to a single panel.
function M.focus_panel_widget(panel_id)
    local panel = registered_panels[panel_id]
    return panel and panel.widget or nil
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
            log.detail("Focus: %s", new_panel.panel_name)
        end
    end

    selection_hub.set_active_panel(focused_panel_id)

    -- Persist the new focus to the project row so the next open lands
    -- on the same panel. Same shape as last_open_sequence_id: written
    -- from the UI signal site, read on layout-restore. Skipped when no
    -- project is open (startup before project_open, headless tests) or
    -- when defocusing all panels (transient state, not user intent).
    if focused_panel_id then
        local ok_ts, timeline_state = pcall(require, "ui.timeline.timeline_state")
        local project_id = ok_ts and timeline_state.get_project_id() or nil
        if project_id and project_id ~= "" then
            local database = require("core.database")
            database.set_project_setting(project_id, "last_focused_panel", focused_panel_id)
        end
    end

    for _, fn in ipairs(focus_change_callbacks) do
        fn(old_panel_id, focused_panel_id)
    end
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

--- Restore the focused panel from project settings (called by layout
--- after sequence + tab restore). Reads `last_focused_panel` and, if
--- that panel id is currently registered, focuses it. Unknown ids are
--- silently skipped — the caller's pre-existing default focus stands.
function M.restore_persisted_focus(project_id)
    assert(type(project_id) == "string" and project_id ~= "",
        "focus_manager.restore_persisted_focus: project_id required")
    local database = require("core.database")
    local saved = database.get_project_setting(project_id, "last_focused_panel")
    if type(saved) ~= "string" or saved == "" then return end
    if not registered_panels[saved] then return end
    M.focus_panel(saved)
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
        log.warn("focus_panel called with unknown panel %s", tostring(panel_id))
        return false
    end

    -- Prefer the first declared focus widget (e.g., the tree inside the panel)
    local target_widget = panel.widget
    if panel.focus_widgets and panel.focus_widgets[1] then
        target_widget = panel.focus_widgets[1]
    end

    -- Set Qt focus on the target widget
    qt_set_focus(target_widget)
    -- Update visual indicators directly (click-to-focus filter only catches mouse events)
    M.set_focused_panel(panel_id)
    return true
end

--- Register a callback for focus changes.
-- @param fn function(old_panel_id, new_panel_id)
function M.on_focus_change(fn)
    assert(type(fn) == "function",
        "focus_manager.on_focus_change: fn must be a function")
    focus_change_callbacks[#focus_change_callbacks + 1] = fn
end

-- Initialize all registered panels to unfocused state
function M.initialize_all_panels()
    for panel_id, _ in pairs(registered_panels) do
        M.update_header(panel_id, false)
    end
    apply_all_borders()
end

-- ============================================================================
-- View registry
-- ============================================================================

local registered_views = {}

function M.register_view(panel_id, view)
    assert(panel_id, "focus_manager.register_view: panel_id required")
    assert(view, "focus_manager.register_view: view required")
    registered_views[panel_id] = view
end

function M.get_active_view()
    if not focused_panel_id then return nil end
    return registered_views[focused_panel_id]
end

function M.get_view(panel_id)
    return registered_views[panel_id]
end

return M
