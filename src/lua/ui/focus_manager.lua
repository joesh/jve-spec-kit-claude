--- Focus Manager Module
--- Tracks which panel has keyboard focus and provides clear visual feedback
--- Shows a bright colored header/border on the active panel

local M = {}

-- Panel registry: maps panel_id -> {widget, header_widget, panel_name}
local registered_panels = {}

-- Currently focused panel ID
local focused_panel_id = nil

-- Focus indicator colors
local COLORS = {
    focused_header = "#ff8c42",      -- Bright orange for focused panel header
    unfocused_header = "#2a2a2a",    -- Dark gray for unfocused panels
    focused_border = "#ff8c42",      -- Bright orange border
    unfocused_border = "#1a1a1a",    -- Invisible border for unfocused
}

-- Register a panel for focus tracking
-- Args:
--   panel_id: unique identifier (e.g., "project_browser", "timeline", "inspector")
--   widget: the main panel widget (will receive focus events)
--   header_widget: optional separate header widget to highlight
--   panel_name: display name (e.g., "Project Browser")
function M.register_panel(panel_id, widget, header_widget, panel_name)
    if not panel_id or not widget then
        print("WARNING: focus_manager.register_panel: missing panel_id or widget")
        return false
    end

    registered_panels[panel_id] = {
        widget = widget,
        header_widget = header_widget,
        panel_name = panel_name or panel_id
    }

    -- Install focus event handler on this panel
    _G["focus_handler_" .. panel_id] = function(event)
        M.handle_focus_event(panel_id, event)
    end

    qt_set_focus_handler(widget, "focus_handler_" .. panel_id)

    print(string.format("✅ Focus tracking registered for panel: %s", panel_name or panel_id))
    return true
end

-- Handle focus events from Qt
function M.handle_focus_event(panel_id, event)
    if event.focus_in then
        M.set_focused_panel(panel_id)
    else
        -- Focus out - only clear if this was the focused panel
        if focused_panel_id == panel_id then
            M.set_focused_panel(nil)
        end
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
            print(string.format("🎯 Focus: %s", panel.panel_name))
        end
    end
end

-- Update visual indicators for a panel
function M.update_panel_visual(panel_id, is_focused)
    local panel = registered_panels[panel_id]
    if not panel then
        return
    end

    -- MINIMAL APPROACH: Only update header widget to avoid breaking panel internals
    -- Don't set border on main widget - it breaks timeline canvas, tree widgets, etc.
    if panel.header_widget then
        local header_color = is_focused and COLORS.focused_header or COLORS.unfocused_header
        qt_set_widget_stylesheet(panel.header_widget, string.format([[
            QLabel {
                background: %s;
                color: white;
                padding: 4px;
                font-size: 12px;
                border: none;
            }
        ]], header_color))
    end

    -- For panels without a header widget (timeline, inspector, project browser),
    -- just print focus status - don't modify their styling at all
    if not panel.header_widget and is_focused then
        -- Visual feedback is optional - the focused panel just works
        -- We don't need a visual indicator if it breaks the panel
    end
end

-- Get currently focused panel ID
function M.get_focused_panel()
    return focused_panel_id
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
        print(string.format("WARNING: focus_manager.focus_panel: unknown panel %s", panel_id))
        return false
    end

    -- Qt will trigger the focus event which will call our handler
    qt_set_focus(panel.widget)
    return true
end

-- Initialize all registered panels to unfocused state
function M.initialize_all_panels()
    for panel_id, _ in pairs(registered_panels) do
        M.update_panel_visual(panel_id, false)
    end
end

return M
