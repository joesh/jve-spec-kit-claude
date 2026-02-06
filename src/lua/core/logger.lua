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
-- Size: ~377 LOC
-- Volatility: unknown
--
-- @file logger.lua
-- Original intent (unreviewed):
-- Logging System for FCP7 Clone
-- Logger with configurable verbosity levels and output destinations
local logger = {}

-- Log levels (lower number = higher priority)
local LOG_LEVELS = {
    TRACE = 0,
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    FATAL = 5
}

-- Level names for output formatting
local LEVEL_NAMES = {
    [0] = "TRACE",
    [1] = "DEBUG", 
    [2] = "INFO",
    [3] = "WARN",
    [4] = "ERROR",
    [5] = "FATAL"
}

-- Level colors for console output
local LEVEL_COLORS = {
    [0] = "\27[90m",  -- Dark gray for TRACE
    [1] = "\27[36m",  -- Cyan for DEBUG
    [2] = "\27[32m",  -- Green for INFO
    [3] = "\27[33m",  -- Yellow for WARN
    [4] = "\27[31m",  -- Red for ERROR
    [5] = "\27[41m"   -- Red background for FATAL
}

local RESET_COLOR = "\27[0m"

-- Logger configuration
local config = {
    level = LOG_LEVELS.WARN,  -- Default level
    enable_colors = true,
    enable_timestamps = true,
    enable_component_tags = true,
    output_destinations = {
        console = true,
        file = false,
        qt_debug = false
    },
    log_file_path = nil,
    component_filters = {},  -- Can filter by component name
    
    -- Subsystem tracing flags (leaf function debugging)
    trace_flags = {
        qt_widgets = false,      -- Qt widget creation/manipulation
        lua_bindings = false,    -- C++/Lua binding operations  
        timeline_ops = false,    -- Timeline operations and state
        metadata_ops = false,    -- Metadata system operations
        command_dispatch = false, -- Command dispatcher internals
        widget_registry = false, -- Widget registry lifecycle
        error_propagation = false, -- Error context propagation
        file_operations = false,  -- File I/O operations
        memory_management = false, -- RAII and cleanup operations
        event_system = false,    -- Event journal operations
        ui_layout = false,       -- UI layout and positioning
        keyboard_input = false,  -- Keyboard shortcut handling
        database_ops = false     -- Timeline database operations
    }
}

-- Internal state
local log_file_handle = nil
local _init_warning = nil

-- Initialize logger
function logger.init(user_config)
    if user_config then
        for key, value in pairs(user_config) do
            if config[key] ~= nil then
                config[key] = value
            end
        end
    end

    local env_level = os.getenv("JVE_LOG_LEVEL")
    if env_level and env_level ~= "" then
        local ok = logger.setLevel(env_level)
        if not ok then
            error("Invalid JVE_LOG_LEVEL: " .. tostring(env_level))
        end
    end
    
    -- Auto-enable file output with default name if not specified
    if config.output_destinations.file and not config.log_file_path then
        -- Detect if running in test environment by checking program name or arguments
        local program_name = arg and arg[0] or ""
        if program_name:match("unit_test_") or program_name:match("test_") then
            config.log_file_path = "tests/playpen/jve_test.log"
        else
            config.log_file_path = "jve.log"
        end
    end
    
    -- Open log file if needed
    if config.output_destinations.file and config.log_file_path then
        log_file_handle = io.open(config.log_file_path, "a")
        if not log_file_handle then
            -- NSF-OK: console fallback when file open fails; logging must not crash the app
            config.output_destinations.file = false
            -- Store warning to log after initialization completes
            _init_warning = "Failed to open log file: " .. config.log_file_path
        end
    end
    
    -- Log any initialization warnings now that logger is ready
    if _init_warning then
        -- Use pcall to protect against logger function failures
        local success, err = pcall(logger.warn, "logger", _init_warning)
        if not success then
            -- If logger.warn fails, we have a critical system failure
            -- Fall back to stderr as absolute last resort
            io.stderr:write("CRITICAL: Logger system failure - " .. tostring(err) .. "\n")
            io.stderr:write("CRITICAL: Original warning was - " .. _init_warning .. "\n")
            io.stderr:flush()
        end
        _init_warning = nil
    end
end

-- Set log level at runtime
function logger.setLevel(level_name)
    local level = LOG_LEVELS[level_name:upper()]
    if level then
        config.level = level
        return true
    end
    return false
end

-- Get current log level name
function logger.getLevel()
    return LEVEL_NAMES[config.level]
end

-- Check if a level is enabled
function logger.isEnabled(level)
    return level >= config.level
end

-- Check if subsystem tracing is enabled
function logger.isTraceEnabled(subsystem)
    return config.trace_flags[subsystem] == true and logger.isEnabled(LOG_LEVELS.TRACE)
end

-- Format timestamp
local function formatTimestamp()
    if not config.enable_timestamps then
        return ""
    end
    return os.date("[%H:%M:%S] ")
end

-- Format component tag
local function formatComponent(component)
    if not config.enable_component_tags or not component then
        return ""
    end
    return "[" .. component .. "] "
end

-- Format log message
local function formatMessage(level, component, message)
    local timestamp = formatTimestamp()
    local comp_tag = formatComponent(component)
    local level_name = LEVEL_NAMES[level]
    
    local formatted = timestamp .. comp_tag .. level_name .. ": " .. message
    
    -- Add colors for console output
    if config.enable_colors and config.output_destinations.console then
        local color = LEVEL_COLORS[level] or ""
        formatted = color .. formatted .. RESET_COLOR
    end
    
    return formatted
end

-- Core logging function
local function log(level, component, message)
    -- Protect against complete system failure
    if not config then
        io.stderr:write("CRITICAL: Logger not initialized - " .. tostring(message) .. "\n")
        io.stderr:flush()
        return
    end
    
    -- Early exit if level not enabled
    if not logger.isEnabled(level) then
        return
    end
    
    -- Check component filter
    if component and config.component_filters[component] == false then
        return
    end
    
    -- Format message without colors first
    local timestamp = formatTimestamp()
    local comp_tag = formatComponent(component)
    local level_name = LEVEL_NAMES[level]
    local base_message = timestamp .. comp_tag .. level_name .. ": " .. (message or "")
    
    -- Output to destinations
    if config.output_destinations.console then
        -- Add colors for console
        local console_message = base_message
        if config.enable_colors then
            local color = LEVEL_COLORS[level] or ""
            console_message = color .. console_message .. RESET_COLOR
        end
        io.write(console_message .. "\n")
        io.flush()
    end
    
    if config.output_destinations.file and log_file_handle then
        -- File output without colors
        log_file_handle:write(base_message .. "\n")
        log_file_handle:flush()
    end
    
    -- TODO: Add Qt debug output if needed
    -- if config.output_destinations.qt_debug then
    --     qt_debug_output(formatted)
    -- end
end

-- Public logging functions
function logger.trace(component, message)
    log(LOG_LEVELS.TRACE, component, message)
end

function logger.debug(component, message)
    log(LOG_LEVELS.DEBUG, component, message)
end

function logger.info(component, message)
    log(LOG_LEVELS.INFO, component, message)
end

function logger.warn(component, message)
    log(LOG_LEVELS.WARN, component, message)
end

function logger.error(component, message)
    log(LOG_LEVELS.ERROR, component, message)
end

function logger.fatal(component, message)
    log(LOG_LEVELS.FATAL, component, message)
end

-- Subsystem-specific trace logging (only logs if subsystem flag enabled)
function logger.traceSubsystem(subsystem, component, message)
    if logger.isTraceEnabled(subsystem) then
        log(LOG_LEVELS.TRACE, component, "[" .. subsystem:upper() .. "] " .. message)
    end
end

-- Convenience functions for common use cases
function logger.timeline(level, message)
    log(LOG_LEVELS[level:upper()], "timeline", message)
end

function logger.metadata(level, message)
    log(LOG_LEVELS[level:upper()], "metadata", message)
end

function logger.ui(level, message)
    log(LOG_LEVELS[level:upper()], "ui", message)
end

function logger.inspector(level, message)
    log(LOG_LEVELS[level:upper()], "inspector", message)
end

-- Filter management
function logger.enableComponent(component)
    config.component_filters[component] = true
end

function logger.disableComponent(component)
    config.component_filters[component] = false
end

function logger.clearFilters()
    config.component_filters = {}
end

-- Subsystem trace flag management
function logger.enableTrace(subsystem)
    if config.trace_flags[subsystem] ~= nil then
        config.trace_flags[subsystem] = true
        logger.info("logger", "Enabled " .. subsystem .. " tracing")
        return true
    else
        logger.warn("logger", "Unknown subsystem: " .. tostring(subsystem))
        return false
    end
end

function logger.disableTrace(subsystem)
    if config.trace_flags[subsystem] ~= nil then
        config.trace_flags[subsystem] = false
        logger.info("logger", "Disabled " .. subsystem .. " tracing")
        return true
    else
        logger.warn("logger", "Unknown subsystem: " .. tostring(subsystem))
        return false
    end
end

function logger.enableAllTracing()
    for subsystem, _ in pairs(config.trace_flags) do
        config.trace_flags[subsystem] = true
    end
    logger.info("logger", "Enabled all subsystem tracing")
end

function logger.disableAllTracing()
    for subsystem, _ in pairs(config.trace_flags) do
        config.trace_flags[subsystem] = false
    end
    logger.info("logger", "Disabled all subsystem tracing")
end

function logger.listTraceFlags()
    logger.info("logger", "Subsystem trace flags:")
    for subsystem, enabled in pairs(config.trace_flags) do
        local status = enabled and "ENABLED" or "disabled"
        logger.info("logger", "  " .. subsystem .. ": " .. status)
    end
end

-- Configuration management
function logger.setOutputFile(file_path)
    -- Close existing file
    if log_file_handle then
        log_file_handle:close()
        log_file_handle = nil
    end
    
    config.log_file_path = file_path
    config.output_destinations.file = true
    
    -- Try to open new file
    log_file_handle = io.open(file_path, "a")
    if not log_file_handle then
        config.output_destinations.file = false
        logger.warn("logger", "Failed to open log file: " .. file_path)
        return false
    end
    
    return true
end

function logger.enableColors(enable)
    config.enable_colors = enable
end

function logger.enableTimestamps(enable)
    config.enable_timestamps = enable
end

-- File management utilities
function logger.enableFileOutput(file_path)
    if not file_path then
        -- Use smart default based on environment
        local program_name = arg and arg[0] or ""
        if program_name:match("unit_test_") or program_name:match("test_") then
            file_path = "tests/playpen/jve_test.log"
        else
            file_path = "jve.log"
        end
    end
    config.log_file_path = file_path
    config.output_destinations.file = true
    
    -- Open log file
    if log_file_handle then
        log_file_handle:close()
    end
    
    log_file_handle = io.open(config.log_file_path, "a")
    if not log_file_handle then
        config.output_destinations.file = false
        logger.error("logger", "Failed to open log file: " .. config.log_file_path)
        return false
    end
    
    logger.info("logger", "File logging enabled: " .. config.log_file_path)
    return true
end

function logger.disableFileOutput()
    config.output_destinations.file = false
    if log_file_handle then
        log_file_handle:close()
        log_file_handle = nil
    end
    logger.info("logger", "File logging disabled")
end

function logger.getConfig()
    return {
        level = config.level,
        enable_colors = config.enable_colors,
        enable_timestamps = config.enable_timestamps,
        output_destinations = config.output_destinations,
        log_file_path = config.log_file_path
    }
end

-- Shutdown
function logger.shutdown()
    if log_file_handle then
        log_file_handle:close()
        log_file_handle = nil
    end
end

-- Integration with error system
function logger.logError(error_obj)
    if not error_obj then
        return
    end
    
    if error_obj.success then
        return  -- Don't log success objects
    end
    
    local component = error_obj.component or "unknown"
    local message = error_obj.user_message or error_obj.message or "Unknown error"
    
    if error_obj.severity == "critical" then
        logger.fatal(component, message)
    elseif error_obj.severity == "error" then
        logger.error(component, message)
    elseif error_obj.severity == "warning" then
        logger.warn(component, message)
    else
        logger.info(component, message)
    end
end

-- Convenient leaf-level tracing functions for each subsystem
function logger.traceQt(message)
    logger.traceSubsystem("qt_widgets", "qt", message)
end

function logger.traceLuaBindings(message)
    logger.traceSubsystem("lua_bindings", "lua_bindings", message)
end

function logger.traceTimeline(message)
    logger.traceSubsystem("timeline_ops", "timeline", message)
end

function logger.traceMetadata(message)
    logger.traceSubsystem("metadata_ops", "metadata", message)
end

function logger.traceCommands(message)
    logger.traceSubsystem("command_dispatch", "commands", message)
end

function logger.traceWidgetRegistry(message)
    logger.traceSubsystem("widget_registry", "widgets", message)
end

function logger.traceErrors(message)
    logger.traceSubsystem("error_propagation", "errors", message)
end

function logger.traceFiles(message)
    logger.traceSubsystem("file_operations", "files", message)
end

function logger.traceMemory(message)
    logger.traceSubsystem("memory_management", "memory", message)
end

function logger.traceEvents(message)
    logger.traceSubsystem("event_system", "events", message)
end

function logger.traceLayout(message)
    logger.traceSubsystem("ui_layout", "layout", message)
end

function logger.traceKeyboard(message)
    logger.traceSubsystem("keyboard_input", "keyboard", message)
end

function logger.traceDatabase(message)
    logger.traceSubsystem("database_ops", "database", message)
end

-- Export constants for external use
logger.LEVELS = LOG_LEVELS
logger.LEVEL_NAMES = LEVEL_NAMES

return logger
