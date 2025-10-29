-- ui/inspector/widget_pool.lua
-- PURPOSE: Manages a pool of reusable Qt widgets for the inspector panel
-- Widgets are created once and reused to prevent resource leaks and signal connection issues

local logger = require("core.logger")
local ui_constants = require("core.ui_constants")
local qt_constants = require("core.qt_constants")

local M = {
    _pools = {
        line_edit = {},
        slider = {},
        checkbox = {},
        combobox = {},
        label = {}
    },
    _active_widgets = {}, -- Widgets currently in use
    _signal_connections = {} -- Track signal connections per widget
}

-- Create a new widget of the specified type
local function create_widget(widget_type, config)
    local success, widget

    if widget_type == "line_edit" then
        success, widget = pcall(qt_constants.WIDGET.CREATE_LINE_EDIT, config.placeholder or "")
        if success then
            -- Apply DaVinci Resolve styling
            local line_edit_style =
                "QLineEdit { " ..
                "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "border-radius: 3px; " ..
                "padding: 2px 6px; " ..
                "} " ..
                "QLineEdit:focus { " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "background-color: " .. ui_constants.COLORS.FIELD_FOCUS_BACKGROUND_COLOR .. "; " ..
                "}"
            pcall(qt_constants.PROPERTIES.SET_STYLE, widget, line_edit_style)
        end

    elseif widget_type == "slider" then
        success, widget = pcall(qt_constants.WIDGET.CREATE_SLIDER, "horizontal")
        if success then
            -- Apply DaVinci Resolve styling
            local slider_style =
                "QSlider::groove:horizontal { " ..
                "background: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "height: 4px; " ..
                "border-radius: 2px; " ..
                "} " ..
                "QSlider::handle:horizontal { " ..
                "background: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "width: 12px; " ..
                "margin: -4px 0; " ..
                "border-radius: 6px; " ..
                "} " ..
                "QSlider::handle:horizontal:hover { " ..
                "background: " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "}"
            pcall(qt_constants.PROPERTIES.SET_STYLE, widget, slider_style)
        end

    elseif widget_type == "checkbox" then
        success, widget = pcall(qt_constants.WIDGET.CREATE_CHECKBOX, config.label or "")
        if success then
            -- Apply DaVinci Resolve styling
            local checkbox_style =
                "QCheckBox { " ..
                "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                "spacing: 5px; " ..
                "} " ..
                "QCheckBox::indicator { " ..
                "width: 16px; " ..
                "height: 16px; " ..
                "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "border-radius: 3px; " ..
                "} " ..
                "QCheckBox::indicator:checked { " ..
                "background-color: " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "} " ..
                "QCheckBox::indicator:hover { " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "}"
            pcall(qt_constants.PROPERTIES.SET_STYLE, widget, checkbox_style)
        end

    elseif widget_type == "combobox" then
        success, widget = pcall(qt_constants.WIDGET.CREATE_COMBOBOX)
        if success then
            -- Apply DaVinci Resolve styling
            local combobox_style =
                "QComboBox { " ..
                "background-color: " .. ui_constants.COLORS.FIELD_BACKGROUND_COLOR .. "; " ..
                "color: " .. ui_constants.COLORS.FIELD_TEXT_COLOR .. "; " ..
                "border: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "border-radius: 3px; " ..
                "padding: 2px 6px; " ..
                "} " ..
                "QComboBox:focus { " ..
                "border: 1px solid " .. ui_constants.COLORS.FOCUS_BORDER_COLOR .. "; " ..
                "} " ..
                "QComboBox::drop-down { " ..
                "border: none; " ..
                "} " ..
                "QComboBox::down-arrow { " ..
                "image: none; " ..
                "border-left: 1px solid " .. ui_constants.COLORS.FIELD_BORDER_COLOR .. "; " ..
                "width: 12px; " ..
                "}"
            pcall(qt_constants.PROPERTIES.SET_STYLE, widget, combobox_style)
        end

    elseif widget_type == "label" then
        success, widget = pcall(qt_constants.WIDGET.CREATE_LABEL, config.text or "")
    end

    if not success or not widget then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
            "[widget_pool] Failed to create widget of type: " .. widget_type)
        return nil
    end

    return widget
end

-- Rent a widget from the pool (create if pool is empty)
function M.rent(widget_type, config)
    config = config or {}

    local pool = M._pools[widget_type]
    if not pool then
        logger.error(ui_constants.LOGGING.COMPONENT_NAMES.UI,
            "[widget_pool] Unknown widget type: " .. widget_type)
        return nil
    end

    -- Try to get widget from pool
    local widget = table.remove(pool)

    -- If pool is empty, create new widget
    if not widget then
        widget = create_widget(widget_type, config)
        if not widget then
            return nil
        end
        logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI,
            string.format("[widget_pool] Created new %s widget (pool was empty)", widget_type))
    else
        logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI,
            string.format("[widget_pool] Reused %s widget from pool", widget_type))
    end

    -- Mark as active
    M._active_widgets[widget] = widget_type

    -- Configure widget based on config
    if widget_type == "line_edit" then
        if config.text then
            pcall(qt_constants.PROPERTIES.SET_TEXT, widget, config.text)
        end
        if config.placeholder then
            pcall(qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT, widget, config.placeholder)
        end

    elseif widget_type == "slider" then
        if config.min and config.max then
            pcall(qt_constants.PROPERTIES.SET_SLIDER_RANGE, widget, config.min, config.max)
        end
        if config.value then
            pcall(qt_constants.PROPERTIES.SET_SLIDER_VALUE, widget, config.value)
        end

    elseif widget_type == "checkbox" then
        if config.checked ~= nil then
            pcall(qt_constants.PROPERTIES.SET_CHECKED, widget, config.checked)
        end
        if config.label then
            pcall(qt_constants.PROPERTIES.SET_TEXT, widget, config.label)
        end

    elseif widget_type == "combobox" then
        if config.options then
            -- Clear existing items
            pcall(qt_constants.PROPERTIES.CLEAR_COMBOBOX_ITEMS, widget)
            -- Add new items
            for _, option in ipairs(config.options) do
                pcall(qt_constants.PROPERTIES.ADD_COMBOBOX_ITEM, widget, option)
            end
        end
        if config.selected then
            pcall(qt_constants.PROPERTIES.SET_COMBOBOX_CURRENT_TEXT, widget, config.selected)
        end

    elseif widget_type == "label" then
        if config.text then
            pcall(qt_constants.PROPERTIES.SET_TEXT, widget, config.text)
        end
    end

    -- Show widget (it may have been hidden when returned)
    pcall(qt_constants.DISPLAY.SET_VISIBLE, widget, true)

    return widget
end

-- Return a widget to the pool for reuse
function M.return_widget(widget)
    if not widget then
        return
    end

    local widget_type = M._active_widgets[widget]
    if not widget_type then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
            "[widget_pool] Attempted to return widget that wasn't rented")
        return
    end

    -- Disconnect any signal connections
    if M._signal_connections[widget] then
        local qt_signals = require("core.qt_signals")
        for _, connection in ipairs(M._signal_connections[widget]) do
            if connection.signal then
                qt_signals.disconnect(widget, connection.signal)
            end
        end
        M._signal_connections[widget] = nil
    end

    -- Hide widget (reduces rendering overhead)
    pcall(qt_constants.DISPLAY.SET_VISIBLE, widget, false)

    -- Clear widget state
    if widget_type == "line_edit" then
        pcall(qt_constants.PROPERTIES.SET_TEXT, widget, "")
        pcall(qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT, widget, "")
    elseif widget_type == "slider" then
        pcall(qt_constants.PROPERTIES.SET_SLIDER_VALUE, widget, 0)
    elseif widget_type == "checkbox" then
        pcall(qt_constants.PROPERTIES.SET_CHECKED, widget, false)
    elseif widget_type == "combobox" then
        pcall(qt_constants.PROPERTIES.CLEAR_COMBOBOX_ITEMS, widget)
    elseif widget_type == "label" then
        pcall(qt_constants.PROPERTIES.SET_TEXT, widget, "")
    end

    -- Mark as inactive
    M._active_widgets[widget] = nil

    -- Return to pool
    local pool = M._pools[widget_type]
    table.insert(pool, widget)

    logger.debug(ui_constants.LOGGING.COMPONENT_NAMES.UI,
        string.format("[widget_pool] Returned %s widget to pool (pool size: %d)",
            widget_type, #pool))
end

-- Connect a signal handler to a widget (tracked for cleanup)
function M.connect_signal(widget, signal_name, handler)
    local qt_signals = require("core.qt_signals")

    local result
    local wrapped_handler
    wrapped_handler = function(...)
        local ok, err = pcall(handler, ...)
        if not ok then
            print(string.format("[widget_pool] Handler for signal '%s' failed: %s", signal_name, tostring(err)))
            print(debug.traceback(err, 2))
        end
    end

    if signal_name == "textChanged" then
        result = qt_signals.onTextChanged(widget, wrapped_handler)
    elseif signal_name == "clicked" then
        result = qt_signals.connect(widget, "clicked", wrapped_handler)
    elseif signal_name == "valueChanged" then
        result = qt_signals.onValueChanged(widget, wrapped_handler)
    else
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
            "[widget_pool] Unknown signal type: " .. signal_name)
        return false
    end

    if type(result) == "table" and result.success == false then
        logger.warn(ui_constants.LOGGING.COMPONENT_NAMES.UI,
            "[widget_pool] Failed to connect signal '" .. signal_name .. "': " .. (result.message or "unknown error"))
        return false
    end

    -- Track connection for cleanup
    if not M._signal_connections[widget] then
        M._signal_connections[widget] = {}
    end
    table.insert(M._signal_connections[widget], {
        signal = signal_name,
        connection_id = result,
        handler = wrapped_handler
    })

    return result
end

-- Get pool statistics (for debugging)
function M.get_stats()
    local stats = {
        pools = {},
        active_count = 0
    }

    for widget_type, pool in pairs(M._pools) do
        stats.pools[widget_type] = #pool
    end

    for _, _ in pairs(M._active_widgets) do
        stats.active_count = stats.active_count + 1
    end

    return stats
end

-- Clear all pools (for cleanup)
function M.clear()
    M._pools = {
        line_edit = {},
        slider = {},
        checkbox = {},
        combobox = {},
        label = {}
    }
    M._active_widgets = {}
    M._signal_connections = {}

    logger.info(ui_constants.LOGGING.COMPONENT_NAMES.UI,
        "[widget_pool] All pools cleared")
end

return M
