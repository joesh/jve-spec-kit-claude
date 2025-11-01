-- Qt Signal Bridge - Maps Qt signals to general signal system
-- Provides clean interface for connecting Qt widget signals to Lua handlers
-- Uses the general signals module for consistency with user-defined signals

local signals = require("core.signals")
local error_system = require("core.error_system")
local qt_constants = require("core.qt_constants")

local QtSignals = {}

-- Registry of Qt widget signal connections for cleanup
local qt_connections = {} -- widget -> {signal_name -> connection_id}

-- Map Qt signal names to their actual Qt function names
local qt_signal_map = {
    clicked = "qt_set_button_click_handler",
    textChanged = "qt_set_line_edit_text_changed_handler",
    editingFinished = "qt_set_line_edit_editing_finished_handler",
    click = "qt_set_widget_click_handler"
}

-- Connect a Qt widget signal to a Lua handler
-- widget: Qt widget userdata
-- signal_name: string - Qt signal name ("clicked", "textChanged", etc.)
-- handler: function - Lua callback function  
-- Returns: connection_id or error
function QtSignals.connect(widget, signal_name, handler)
    -- Input validation (fail early)
    if not widget then
        return error_system.create_error({
            code = "INVALID_WIDGET",
            category = "qt_signals",
            message = "Widget cannot be nil",
            operation = "connect",
            user_message = "Cannot connect Qt signal: no widget provided"
        })
    end
    
    if type(signal_name) ~= "string" then
        return error_system.create_error({
            code = "INVALID_SIGNAL_NAME",
            category = "qt_signals", 
            message = "Signal name must be a string",
            operation = "connect",
            user_message = "Cannot connect Qt signal: invalid signal name",
            technical_details = {
                signal_name = signal_name,
                signal_type = type(signal_name)
            }
        })
    end
    
    if type(handler) ~= "function" then
        return error_system.create_error({
            code = "INVALID_HANDLER",
            category = "qt_signals",
            message = "Handler must be a function", 
            operation = "connect",
            user_message = "Cannot connect Qt signal: invalid handler"
        })
    end
    
    -- Check if Qt signal is supported
    local qt_function_name = qt_signal_map[signal_name]
    if not qt_function_name then
        return error_system.create_error({
            code = "UNSUPPORTED_SIGNAL",
            category = "qt_signals",
            message = "Qt signal not supported",
            operation = "connect",
            user_message = "Cannot connect Qt signal: signal not supported",
            technical_details = {
                signal_name = signal_name,
                supported_signals = signals.list_keys(qt_signal_map)
            }
        })
    end
    
    -- Generate unique signal name for this widget + signal combination
    local widget_id = tostring(widget) -- Use widget memory address as unique ID
    local unique_signal_name = "qt:" .. widget_id .. ":" .. signal_name
    
    -- Connect to general signal system
    local connection_id = signals.connect(unique_signal_name, handler)
    if error_system.is_error(connection_id) then
        return connection_id -- Propagate error
    end
    
    -- Create Qt-side connection using global handler function
    local qt_handler_name = "qt_signal_" .. connection_id
    
    -- Register global handler function that emits to our signal system
    _G[qt_handler_name] = function(...)
        local ok, results_or_error = pcall(signals.emit, unique_signal_name, ...)
        if not ok then
            local err_msg = tostring(results_or_error)
            local connection_info = signals._debug_get_connection(connection_id)
            local creation_trace = connection_info and connection_info.creation_trace or "(unknown)"
            local handler_type = connection_info and type(connection_info.handler) or "(unknown)"
            print(string.format(
                "ERROR: Qt signal dispatch failed (signal=%s, connection=%s, handler_type=%s): %s",
                unique_signal_name,
                tostring(connection_id),
                handler_type,
                err_msg
            ))
            print("-- Handler creation trace --")
            print(creation_trace)
            return
        end

        local results = results_or_error
        -- Qt callbacks typically don't need return values, but we log errors
        for _, result in ipairs(results) do
            if not result.success then
                -- Log handler error but don't fail Qt operation
                local prefix = string.format(
                    "WARNING: Qt signal handler failed (signal=%s, connection=%s, handler_type=%s)",
                    unique_signal_name,
                    tostring(result.connection_id),
                    tostring(result.handler_type)
                )
                print(prefix .. ": " .. tostring(result.error))
                if result.creation_trace then
                    print("-- Handler creation trace --")
                    print(result.creation_trace)
                end
            end
        end
    end
    
    -- Set up Qt signal connection using appropriate Qt function
    local qt_function = _G[qt_function_name]
    if not qt_function then
        return error_system.create_error({
            code = "QT_FUNCTION_NOT_FOUND",
            category = "qt_signals",
            message = "Qt function not available",
            operation = "connect", 
            user_message = "Cannot connect Qt signal: Qt binding missing",
            technical_details = {
                qt_function_name = qt_function_name
            }
        })
    end
    
    -- Call Qt function to set up C++ signal connection
    local success, error_msg = pcall(qt_function, widget, qt_handler_name)
    if not success then
        -- Clean up on failure
        signals.disconnect(connection_id)
        _G[qt_handler_name] = nil
        
        return error_system.create_error({
            code = "QT_CONNECTION_FAILED",
            category = "qt_signals",
            message = "Failed to connect Qt signal",
            operation = "connect",
            user_message = "Cannot connect Qt signal: Qt connection failed",
            technical_details = {
                widget = widget,
                signal_name = signal_name, 
                qt_function = qt_function_name,
                error = error_msg
            }
        })
    end
    
    -- Track connection for cleanup
    if not qt_connections[widget] then
        qt_connections[widget] = {}
    end
    qt_connections[widget][signal_name] = {
        connection_id = connection_id,
        qt_handler_name = qt_handler_name,
        unique_signal_name = unique_signal_name
    }
    
    return connection_id
end

-- Disconnect a Qt signal connection
-- widget: Qt widget userdata
-- signal_name: string - Qt signal name
-- Returns: success or error
function QtSignals.disconnect(widget, signal_name)
    if not widget or not qt_connections[widget] then
        return error_system.create_error({
            code = "WIDGET_NOT_CONNECTED",
            category = "qt_signals",
            message = "Widget has no signal connections",
            operation = "disconnect",
            user_message = "Cannot disconnect: widget not connected"
        })
    end
    
    local connection_info = qt_connections[widget][signal_name]
    if not connection_info then
        return error_system.create_error({
            code = "SIGNAL_NOT_CONNECTED",
            category = "qt_signals", 
            message = "Signal not connected on widget",
            operation = "disconnect",
            user_message = "Cannot disconnect: signal not connected",
            technical_details = {
                signal_name = signal_name
            }
        })
    end
    
    -- Disconnect from general signal system
    local disconnect_result = signals.disconnect(connection_info.connection_id)
    if error_system.is_error(disconnect_result) then
        return disconnect_result
    end
    
    -- Clean up global handler function
    _G[connection_info.qt_handler_name] = nil
    
    -- Remove from tracking
    qt_connections[widget][signal_name] = nil
    
    -- Clean up empty widget entries
    local has_connections = false
    for _ in pairs(qt_connections[widget]) do
        has_connections = true
        break
    end
    if not has_connections then
        qt_connections[widget] = nil
    end
    
    return error_system.create_success({
        message = "Qt signal disconnected successfully"
    })
end

-- Convenience functions for common Qt signals

function QtSignals.onClick(widget, handler)
    return QtSignals.connect(widget, "clicked", handler)
end

function QtSignals.onTextChanged(widget, handler)
    return QtSignals.connect(widget, "textChanged", handler)
end

function QtSignals.onWidgetClick(widget, handler)
    return QtSignals.connect(widget, "click", handler)
end

-- Debug function to list all Qt connections
function QtSignals.list_connections()
    local connections_list = {}
    for widget, widget_connections in pairs(qt_connections) do
        local widget_info = {
            widget = tostring(widget),
            signals = {}
        }
        for signal_name, connection_info in pairs(widget_connections) do
            table.insert(widget_info.signals, {
                signal = signal_name,
                connection_id = connection_info.connection_id
            })
        end
        table.insert(connections_list, widget_info)
    end
    return connections_list
end

-- Cleanup function for testing
function QtSignals.clear_all()
    for widget, widget_connections in pairs(qt_connections) do
        for signal_name, connection_info in pairs(widget_connections) do
            signals.disconnect(connection_info.connection_id)
            _G[connection_info.qt_handler_name] = nil
        end
    end
    qt_connections = {}
    return error_system.create_success({
        message = "All Qt connections cleared"
    })
end

return QtSignals
