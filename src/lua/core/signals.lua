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
-- Size: ~213 LOC
-- Volatility: unknown
--
-- @file signals.lua
-- Original intent (unreviewed):
-- General-purpose signal/slot system for JVE
-- Inspired by Emacs hooks and Qt signals for maximum user extensibility
-- Provides unified event system for Qt signals, Lua-to-Lua communication, and user extensions
local error_system = require("core.error_system")
local unpack = table.unpack or unpack

local Signals = {}

-- Private signal registry: signal_name -> list of handlers
local signal_registry = {}

-- Private connection ID counter for tracking connections
local connection_id_counter = 0

-- Connection management for disconnection
local connections = {} -- connection_id -> {signal_name, handler}

-- Create a new signal connection
-- signal_name: string - name of the signal
-- handler: function - callback function to execute
-- priority: number (optional) - lower numbers execute first (default: 100)
-- Returns: connection_id for later disconnection, or error
function Signals.connect(signal_name, handler, priority)
    -- Input validation (fail early principle)
    if type(signal_name) ~= "string" then
        return error_system.create_error({
            code = "INVALID_SIGNAL_NAME",
            category = "signals",
            message = "Signal name must be a string",
            operation = "connect",
            user_message = "Cannot connect signal: invalid signal name",
            technical_details = {
                signal_name = signal_name,
                signal_type = type(signal_name)
            }
        })
    end
    
    if signal_name == "" then
        return error_system.create_error({
            code = "EMPTY_SIGNAL_NAME",
            category = "signals",
            message = "Signal name cannot be empty",
            operation = "connect",
            user_message = "Cannot connect signal: signal name is empty"
        })
    end
    
    if type(handler) ~= "function" then
        return error_system.create_error({
            code = "INVALID_HANDLER",
            category = "signals", 
            message = "Handler must be a function",
            operation = "connect",
            user_message = "Cannot connect signal: invalid handler",
            technical_details = {
                handler = handler,
                handler_type = type(handler)
            }
        })
    end
    
    priority = priority or 100
    if type(priority) ~= "number" then
        return error_system.create_error({
            code = "INVALID_PRIORITY",
            category = "signals",
            message = "Priority must be a number",
            operation = "connect", 
            user_message = "Cannot connect signal: invalid priority",
            technical_details = {
                priority = priority,
                priority_type = type(priority)
            }
        })
    end
    
    -- Initialize signal registry if first connection
    if not signal_registry[signal_name] then
        signal_registry[signal_name] = {}
    end
    
    -- Create connection record
    connection_id_counter = connection_id_counter + 1
    local connection_id = connection_id_counter
    
    local connection_record = {
        id = connection_id,
        handler = handler,
        priority = priority,
        signal_name = signal_name,
        creation_trace = debug.traceback("Signal connection created here", 2)
    }
    
    -- Insert in priority order (lower priority numbers first)
    local handlers = signal_registry[signal_name]
    local inserted = false
    for i, existing in ipairs(handlers) do
        if priority < existing.priority then
            table.insert(handlers, i, connection_record)
            inserted = true
            break
        end
    end
    
    if not inserted then
        table.insert(handlers, connection_record)
    end
    
    -- Track connection for disconnection
    connections[connection_id] = connection_record
    
    return connection_id
end

-- Debug helper to inspect a connection record (read-only)
function Signals._debug_get_connection(connection_id)
    return connections[connection_id]
end

-- Disconnect a signal connection
-- connection_id: number - ID returned from connect()
-- Returns: success or error
function Signals.disconnect(connection_id)
    if type(connection_id) ~= "number" then
        return error_system.create_error({
            code = "INVALID_CONNECTION_ID",
            category = "signals",
            message = "Connection ID must be a number",
            operation = "disconnect",
            user_message = "Cannot disconnect: invalid connection ID"
        })
    end
    
    local connection = connections[connection_id]
    if not connection then
        return error_system.create_error({
            code = "CONNECTION_NOT_FOUND", 
            category = "signals",
            message = "Connection ID not found",
            operation = "disconnect",
            user_message = "Cannot disconnect: connection not found",
            technical_details = {
                connection_id = connection_id
            }
        })
    end
    
    -- Remove from signal registry
    local handlers = signal_registry[connection.signal_name]
    if handlers then
        for i, handler_record in ipairs(handlers) do
            if handler_record.id == connection_id then
                table.remove(handlers, i)
                break
            end
        end
        
        -- Clean up empty signal registries
        if #handlers == 0 then
            signal_registry[connection.signal_name] = nil
        end
    end
    
    -- Remove from connection tracking
    connections[connection_id] = nil
    
    return error_system.create_success({
        message = "Signal disconnected successfully"
    })
end

-- Emit a signal to all connected handlers
-- signal_name: string - name of the signal to emit
-- ...: any - arguments to pass to handlers
-- Returns: table of results from each handler, or error
function Signals.emit(signal_name, ...)
    if type(signal_name) ~= "string" then
        return error_system.create_error({
            code = "INVALID_SIGNAL_NAME",
            category = "signals",
            message = "Signal name must be a string",
            operation = "emit",
            user_message = "Cannot emit signal: invalid signal name"
        })
    end
    
    local handlers = signal_registry[signal_name]
    if not handlers or #handlers == 0 then
        -- No handlers registered - this is not an error, just return empty results
        return {}
    end
    
    local results = {}
    local args = {...}
    
    -- Execute handlers in priority order
    for i, handler_record in ipairs(handlers) do
        if handler_record.handler == nil then
            error(string.format(
                "Signal '%s' connection %s has no handler (index %d, total %d)\nCreation trace:\n%s",
                signal_name,
                tostring(handler_record.id),
                i,
                #handlers,
                handler_record.creation_trace or "(unknown)"
            ))
        end

        local success, result = pcall(handler_record.handler, unpack(args))
        
        local handler_result = {
            connection_id = handler_record.id,
            success = success,
            result = result,
            creation_trace = handler_record.creation_trace,
            handler_type = type(handler_record.handler)
        }
        
        if not success then
            print(string.format(
                "[signals] Handler failure: signal=%s connection=%s handler=%s (%s) error=%s",
                signal_name,
                tostring(handler_record.id),
                tostring(handler_record.handler),
                type(handler_record.handler),
                tostring(result)
            ))
            -- Handler failed - include error information but continue with other handlers
            handler_result.error = result
        end
        
        table.insert(results, handler_result)
    end
    
    return results
end

-- Get list of signals with handler counts (for debugging/monitoring)
function Signals.list_signals()
    local signal_list = {}
    for signal_name, handlers in pairs(signal_registry) do
        table.insert(signal_list, {
            name = signal_name,
            handler_count = #handlers,
            handlers = handlers -- Include full handler info for debugging
        })
    end
    return signal_list
end

-- Clear all signal connections (for testing/cleanup)
function Signals.clear_all()
    signal_registry = {}
    connections = {}
    connection_id_counter = 0
    return error_system.create_success({
        message = "All signals cleared"
    })
end

-- User extension point: Hook system (Emacs-style)
-- Provides simple hook interface on top of general signal system
Signals.hooks = {}

function Signals.hooks.add(hook_name, handler, priority)
    return Signals.connect(hook_name, handler, priority)
end

function Signals.hooks.remove(connection_id)
    return Signals.disconnect(connection_id)
end

function Signals.hooks.run(hook_name, ...)
    local results = Signals.emit(hook_name, ...)
    
    -- For hooks, we typically only care about successful execution
    local successful_results = {}
    for _, result in ipairs(results) do
        if result.success then
            table.insert(successful_results, result.result)
        end
    end
    
    return successful_results
end

return Signals
