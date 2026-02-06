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
-- Size: ~433 LOC
-- Volatility: unknown
--
-- @file error_system.lua
-- Original intent (unreviewed):
-- Comprehensive Error Handling System for Final Cut Pro 7 Clone
-- Provides comprehensive error propagation with context building and remediation suggestions
local error_system = {}

-- Error categories with specific handling strategies
local ERROR_CATEGORIES = {
    QT_WIDGET = "qt_widget",
    QT_LAYOUT = "qt_layout", 
    INSPECTOR = "inspector",
    METADATA = "metadata",
    COMMAND = "command",
    LUA_ENGINE = "lua_engine",
    SYSTEM = "system"
}

-- Error severity levels
local ERROR_SEVERITY = {
    CRITICAL = "critical",   -- System cannot continue, user must take action
    ERROR = "error",         -- Feature broken but system can continue
    WARNING = "warning",     -- Potential issue, feature may degrade
    INFO = "info"           -- Informational, no action needed
}

-- Error codes organized by functional area
local ERROR_CODES = {
    -- Widget Creation and Management
    QT_WIDGET_CREATION_FAILED = "QT_WIDGET_CREATION_FAILED",
    WIDGET_CREATION_FAILED = "WIDGET_CREATION_FAILED",
    WIDGET_ADD_FAILED = "WIDGET_ADD_FAILED",
    WIDGET_SHOW_FAILED = "WIDGET_SHOW_FAILED",
    WIDGET_ACTIVATE_FAILED = "WIDGET_ACTIVATE_FAILED",
    WIDGET_RAISE_FAILED = "WIDGET_RAISE_FAILED",
    CENTRAL_WIDGET_CREATION_FAILED = "CENTRAL_WIDGET_CREATION_FAILED",
    CENTRAL_WIDGET_SET_FAILED = "CENTRAL_WIDGET_SET_FAILED",
    CONTENT_WIDGET_CREATION_FAILED = "CONTENT_WIDGET_CREATION_FAILED",
    DOCK_WIDGET_CREATE_FAILED = "DOCK_WIDGET_CREATE_FAILED",
    SCROLL_AREA_CREATION_FAILED = "SCROLL_AREA_CREATION_FAILED",
    
    -- Layout Management
    LAYOUT_CREATION_FAILED = "LAYOUT_CREATION_FAILED",
    LAYOUT_SET_FAILED = "LAYOUT_SET_FAILED",
    LAYOUT_ADD_FAILED = "LAYOUT_ADD_FAILED",
    LAYOUT_ADD_WIDGET_FAILED = "LAYOUT_ADD_WIDGET_FAILED",
    LAYOUT_ASSIGNMENT_FAILED = "LAYOUT_ASSIGNMENT_FAILED",
    CONTENT_LAYOUT_CREATION_FAILED = "CONTENT_LAYOUT_CREATION_FAILED",
    CONTENT_LAYOUT_NOT_FOUND = "CONTENT_LAYOUT_NOT_FOUND",
    FIELD_LAYOUT_CREATION_FAILED = "FIELD_LAYOUT_CREATION_FAILED",
    
    -- Widget Parenting and Hierarchy
    PARENT_TYPE_DETECTION_FAILED = "PARENT_TYPE_DETECTION_FAILED",
    CHILD_TYPE_DETECTION_FAILED = "CHILD_TYPE_DETECTION_FAILED",
    PARENT_CANNOT_HAVE_CHILDREN = "PARENT_CANNOT_HAVE_CHILDREN",
    UNSUPPORTED_PARENTING_COMBINATION = "UNSUPPORTED_PARENTING_COMBINATION",
    IMMEDIATE_PARENTING_FAILED = "IMMEDIATE_PARENTING_FAILED",
    MAIN_WINDOW_PARENTING_FAILED = "MAIN_WINDOW_PARENTING_FAILED",
    SCROLL_AREA_PARENTING_FAILED = "SCROLL_AREA_PARENTING_FAILED",
    
    -- Window Management
    MAIN_WINDOW_CREATION_FAILED = "MAIN_WINDOW_CREATION_FAILED",
    WINDOW_NOT_FOUND = "WINDOW_NOT_FOUND",
    WINDOW_SHOW_FAILED = "WINDOW_SHOW_FAILED",
    WINDOW_RAISE_FAILED = "WINDOW_RAISE_FAILED",
    WINDOW_RESIZE_FAILED = "WINDOW_RESIZE_FAILED",
    WINDOW_POSITION_SET_FAILED = "WINDOW_POSITION_SET_FAILED",
    WINDOW_TITLE_SET_FAILED = "WINDOW_TITLE_SET_FAILED",
    GEOMETRY_RESTORE_FAILED = "GEOMETRY_RESTORE_FAILED",
    VISIBILITY_SET_FAILED = "VISIBILITY_SET_FAILED",
    
    -- Inspector and Metadata
    INSPECTOR_001 = "INSPECTOR_001",
    INSPECTOR_002 = "INSPECTOR_002",
    INSPECTOR_009 = "INSPECTOR_009",
    INSPECTOR_CREATION_FAILED = "INSPECTOR_CREATION_FAILED",
    INSPECTOR_EMBED_FAILED = "INSPECTOR_EMBED_FAILED",
    INSPECTOR_SECTIONS_FAILED = "INSPECTOR_SECTIONS_FAILED",
    SELECTION_INSPECTOR_INIT_FAILED = "SELECTION_INSPECTOR_INIT_FAILED",
    SECTION_ADD_FAILED = "SECTION_ADD_FAILED",
    SECTION_NOT_INITIALIZED = "SECTION_NOT_INITIALIZED",
    
    -- Field Types and Form Controls
    FIELD_CONTAINER_CREATION_FAILED = "FIELD_CONTAINER_CREATION_FAILED",
    FIELD_WIDGET_CREATION_FAILED = "FIELD_WIDGET_CREATION_FAILED",
    LABEL_CREATION_FAILED = "LABEL_CREATION_FAILED",
    INPUT_CREATION_FAILED = "INPUT_CREATION_FAILED",
    UNSUPPORTED_FIELD_TYPE = "UNSUPPORTED_FIELD_TYPE",
    INVALID_DEFAULT_TYPE = "INVALID_DEFAULT_TYPE",
    MISSING_FIELD_DEFAULT = "MISSING_FIELD_DEFAULT",
    MISSING_DROPDOWN_OPTIONS = "MISSING_DROPDOWN_OPTIONS",
    
    -- Not Implemented Field Types
    CHECKBOX_NOT_IMPLEMENTED = "CHECKBOX_NOT_IMPLEMENTED",
    COMBO_BOX_NOT_IMPLEMENTED = "COMBO_BOX_NOT_IMPLEMENTED",
    TEXT_EDIT_NOT_IMPLEMENTED = "TEXT_EDIT_NOT_IMPLEMENTED",
    DATETIME_NOT_IMPLEMENTED = "DATETIME_NOT_IMPLEMENTED",
    TIMECODE_NOT_IMPLEMENTED = "TIMECODE_NOT_IMPLEMENTED",
    
    -- Graphics and Timeline Rendering
    GRAPHICS_SCENE_CREATION_FAILED = "GRAPHICS_SCENE_CREATION_FAILED",
    GRAPHICS_VIEW_CREATION_FAILED = "GRAPHICS_VIEW_CREATION_FAILED",
    CLIP_RECTANGLE_CREATION_FAILED = "CLIP_RECTANGLE_CREATION_FAILED",
    CLIP_RECTANGLE_SCENE_ADD_FAILED = "CLIP_RECTANGLE_SCENE_ADD_FAILED",
    CLIP_TEXT_CREATION_FAILED = "CLIP_TEXT_CREATION_FAILED",
    CLIP_TEXT_SCENE_ADD_FAILED = "CLIP_TEXT_SCENE_ADD_FAILED",
    TIMELINE_DIMENSIONS_NOT_SET = "TIMELINE_DIMENSIONS_NOT_SET",
    TIMELINE_CLIPS_QUERY_FAILED = "TIMELINE_CLIPS_QUERY_FAILED",
    VISIBLE_CLIPS_QUERY_FAILED = "VISIBLE_CLIPS_QUERY_FAILED",
    PIXEL_COLLISION_TEST_FAILED = "PIXEL_COLLISION_TEST_FAILED",
    
    -- Timeline Context and Tools
    TIMELINE_CONTEXT_FAILED = "TIMELINE_CONTEXT_FAILED",
    MISSING_TIMELINE_CONTEXT = "MISSING_TIMELINE_CONTEXT",
    TOOLS_NOT_INITIALIZED = "TOOLS_NOT_INITIALIZED",
    RENDERER_NOT_INITIALIZED = "RENDERER_NOT_INITIALIZED",
    
    -- Event Store and Persistence
    EVENT_STORE_DIR_REQUIRED = "EVENT_STORE_DIR_REQUIRED",
    EVENT_STORE_INVALID_VERSION = "EVENT_STORE_INVALID_VERSION",
    EVENT_STORE_VERSION_NOT_FOUND = "EVENT_STORE_VERSION_NOT_FOUND",
    EVENT_STORE_STAGE_WRITE_FAILED = "EVENT_STORE_STAGE_WRITE_FAILED",
    EVENT_STORE_COMMIT_WRITE_FAILED = "EVENT_STORE_COMMIT_WRITE_FAILED",
    CHECKPOINT_WRITE_FAILED = "CHECKPOINT_WRITE_FAILED",
    
    -- Parameter Validation
    INVALID_PANEL_HANDLE = "INVALID_PANEL_HANDLE",
    INVALID_WIDGET_PARAMS = "INVALID_WIDGET_PARAMS",
    INVALID_WIDGET_TYPE = "INVALID_WIDGET_TYPE",
    INVALID_PARAMETER_TYPE = "INVALID_PARAMETER_TYPE",
    INVALID_SECTION_OBJECT = "INVALID_SECTION_OBJECT",
    INVALID_DOCK_AREA = "INVALID_DOCK_AREA",
    INVALID_MENU_PATH = "INVALID_MENU_PATH",
    MISSING_REQUIRED_FUNCTIONS = "MISSING_REQUIRED_FUNCTIONS",
    
    -- Store Port and Method Validation
    STORE_PORT_MISSING_APPLY_METHOD = "STORE_PORT_MISSING_APPLY_METHOD",
    STORE_PORT_WRAP_MISSING_STORE = "STORE_PORT_WRAP_MISSING_STORE",
    MISSING_ADDCLIP_METHOD = "MISSING_ADDCLIP_METHOD",
    MISSING_PLAY_METHOD = "MISSING_PLAY_METHOD",
    
    -- Menu and UI Actions
    MENU_CREATE_FAILED = "MENU_CREATE_FAILED",
    MENU_ACTION_ADD_FAILED = "MENU_ACTION_ADD_FAILED",
    MENU_SEPARATOR_ADD_FAILED = "MENU_SEPARATOR_ADD_FAILED",
    
    -- JSON and File Processing
    JSON_DECODE_ERROR = "JSON_DECODE_ERROR",
    JSON_UNSUPPORTED_TYPE = "JSON_UNSUPPORTED_TYPE",
    PRESET_FILE_NOT_FOUND = "PRESET_FILE_NOT_FOUND",
    INVALID_PRESET_FILE = "INVALID_PRESET_FILE",
    
    -- Runtime and Engine Errors
    LUA_RUNTIME_ERROR = "LUA_RUNTIME_ERROR",
    FFMPEG_XFADE_CLIP_MISSING = "FFMPEG_XFADE_CLIP_MISSING"
}

-- Create a new error with full context
function error_system.create_error(params)
    -- Validate required parameters
    if type(params) ~= "table" then
        local stack = debug.traceback("error_system.create_error validation failed", 2)
        error("error_system.create_error: params must be a table, got " .. type(params) .. "\n" .. stack)
    end
    
    local message = params.message
    if not message or type(message) ~= "string" or message == "" then
        local stack = debug.traceback("error_system.create_error validation failed", 2)
        error("error_system.create_error: params.message must be a non-empty string, got " .. type(message) .. " (" .. tostring(message) .. ")\n" .. stack)
    end
    
    return {
        -- Core error information
        code = assert(params.code, "error_system.create_error: params.code is required"),
        category = params.category or ERROR_CATEGORIES.SYSTEM, -- NSF-OK: SYSTEM is safe default category
        severity = params.severity or ERROR_SEVERITY.ERROR, -- NSF-OK: ERROR is safe default severity
        message = params.message,

        -- Context information (builds up through call stack)
        operation = assert(params.operation, "error_system.create_error: params.operation is required"),
        component = assert(params.component, "error_system.create_error: params.component is required"),
        context_stack = params.context_stack or {},
        
        -- Technical details
        technical_details = params.technical_details or {},
        parameters = params.parameters or {},
        
        -- User guidance
        user_message = params.user_message or params.message,
        remediation = params.remediation or {},
        
        -- System state
        timestamp = os.time(),
        lua_stack = debug.traceback("", 2), -- Skip this function
        
        -- Success/failure flag for easy checking
        success = false
    }
end

-- Create a success result
function error_system.create_success(params)
    return {
        success = true,
        message = params.message or "Operation completed successfully",
        return_values = params.return_values or {},
        timestamp = os.time()
    }
end

-- Add context to an existing error as it bubbles up
function error_system.add_context(error_obj, context)
    if not error_obj or error_obj.success then
        return error_obj  -- Don't modify success results
    end
    
    -- Ensure context_stack exists
    if not error_obj.context_stack then
        error_obj.context_stack = {}
    end
    
    -- Add new context to the stack
    table.insert(error_obj.context_stack, 1, {
        operation = context.operation or "unknown",
        component = context.component or "unknown",
        details = context.details or {},
        timestamp = os.time()
    })
    
    -- Update top-level context
    if context.operation then error_obj.operation = context.operation end
    if context.component then error_obj.component = context.component end
    
    -- Merge technical details
    if context.technical_details then
        for k, v in pairs(context.technical_details) do
            error_obj.technical_details[k] = v
        end
    end
    
    -- Add remediation suggestions
    if context.remediation then
        for _, suggestion in ipairs(context.remediation) do
            table.insert(error_obj.remediation, suggestion)
        end
    end
    
    -- Update user message if provided
    if context.user_message then
        error_obj.user_message = context.user_message
    end
    
    return error_obj
end

-- Check if a result indicates an error
function error_system.is_error(result)
    return result and type(result) == "table" and result.success == false
end

-- Check if a result indicates success
function error_system.is_success(result)
    return result and type(result) == "table" and result.success == true
end

-- Format error for user display
function error_system.format_user_error(error_obj)
    if not error_obj then
        error("error_system.format_user_error: error_obj cannot be nil")
    end

    if type(error_obj) ~= "table" then
        error("error_system.format_user_error: error_obj must be a table, got " .. type(error_obj))
    end

    if error_obj.success then
        return "No error to format"
    end
    
    if not error_obj.message and not error_obj.user_message then
        local stack = debug.traceback("error_system.format_user_error validation failed", 2)
        error("error_system.format_user_error: error_obj must have either message or user_message field\n" .. 
              "error_obj contents: " .. tostring(error_obj) .. "\n" .. stack)
    end
    
    local lines = {}
    
    -- Main error message
    table.insert(lines, "❌ " .. (error_obj.user_message or error_obj.message))
    table.insert(lines, "")
    
    -- Context chain (most recent first)
    if #error_obj.context_stack > 0 then
        table.insert(lines, "📍 What was happening:")
        for i, context in ipairs(error_obj.context_stack) do
            local indent = string.rep("  ", i - 1)
            table.insert(lines, indent .. "↳ " .. context.operation .. " (" .. context.component .. ")")
        end
        table.insert(lines, "")
    end
    
    -- Technical details (if any)
    if next(error_obj.technical_details) then
        table.insert(lines, "🔧 Technical Details:")
        for key, value in pairs(error_obj.technical_details) do
            table.insert(lines, "  • " .. key .. ": " .. tostring(value))
        end
        table.insert(lines, "")
    end
    
    -- Remediation suggestions
    if #error_obj.remediation > 0 then
        table.insert(lines, "💡 How to fix this:")
        for i, suggestion in ipairs(error_obj.remediation) do
            table.insert(lines, "  " .. i .. ". " .. suggestion)
        end
        table.insert(lines, "")
    end
    
    -- Error code and category
    table.insert(lines, "📋 Error Code: " .. error_obj.code .. " (" .. error_obj.category .. ")")
    
    return table.concat(lines, "\n")
end

-- Format error for developer/debug display
function error_system.format_debug_error(error_obj)
    if not error_obj or error_obj.success then
        return "No error to format"
    end
    
    local lines = {}
    
    table.insert(lines, "=== DEBUG ERROR REPORT ===")
    table.insert(lines, "Code: " .. (error_obj.code or "UNKNOWN"))
    table.insert(lines, "Category: " .. (error_obj.category or "unknown"))
    table.insert(lines, "Severity: " .. (error_obj.severity or "unknown"))
    table.insert(lines, "Operation: " .. (error_obj.operation or "unknown"))
    table.insert(lines, "Component: " .. (error_obj.component or "unknown"))
    table.insert(lines, "Timestamp: " .. os.date("%Y-%m-%d %H:%M:%S", error_obj.timestamp))
    table.insert(lines, "")
    table.insert(lines, "Message: " .. (error_obj.message or "No message"))
    table.insert(lines, "User Message: " .. (error_obj.user_message or "No user message"))
    table.insert(lines, "")
    
    -- Context stack
    if #error_obj.context_stack > 0 then
        table.insert(lines, "Context Stack:")
        for i, context in ipairs(error_obj.context_stack) do
            table.insert(lines, "  [" .. i .. "] " .. context.operation .. " @ " .. context.component)
            if next(context.details) then
                for k, v in pairs(context.details) do
                    table.insert(lines, "      " .. k .. ": " .. tostring(v))
                end
            end
        end
        table.insert(lines, "")
    end
    
    -- Parameters
    if next(error_obj.parameters) then
        table.insert(lines, "Parameters:")
        for k, v in pairs(error_obj.parameters) do
            table.insert(lines, "  " .. k .. ": " .. tostring(v))
        end
        table.insert(lines, "")
    end
    
    -- Technical details
    if next(error_obj.technical_details) then
        table.insert(lines, "Technical Details:")
        for k, v in pairs(error_obj.technical_details) do
            table.insert(lines, "  " .. k .. ": " .. tostring(v))
        end
        table.insert(lines, "")
    end
    
    -- Lua stack trace
    table.insert(lines, "Lua Stack Trace:")
    table.insert(lines, error_obj.lua_stack or "No stack trace available")
    
    table.insert(lines, "=== END DEBUG REPORT ===")
    
    return table.concat(lines, "\n")
end

-- Wrap a function call with error handling
function error_system.safe_call(fn, context, ...)
    local success, result = pcall(fn, ...)
    
    if not success then
        -- Check if this is a JSON-serialized ErrorContext from C++
        local error_string = tostring(result)
        if string.find(error_string, '"type":"rich_error"', 1, true) then
            -- Parse JSON ErrorContext back into Lua table
            local json = require("core.json")
            local success_parse, parsed_error = pcall(json.decode, error_string)
            if success_parse and parsed_error.type == "rich_error" then
                -- Convert C++ ErrorContext JSON back to Lua ErrorContext format
                return {
                    success = false,
                    code = "C++_ERROR_" .. tostring(parsed_error.errorCode or 0),
                    category = ERROR_CATEGORIES.QT_WIDGET, -- C++ errors are typically Qt-related
                    severity = parsed_error.severity == 0 and ERROR_SEVERITY.INFO or
                              parsed_error.severity == 1 and ERROR_SEVERITY.WARNING or
                              parsed_error.severity == 2 and ERROR_SEVERITY.ERROR or
                              ERROR_SEVERITY.CRITICAL,
                    message = parsed_error.message or "C++ error occurred",
                    operation = context.operation or "qt_function_call",
                    component = context.component or "qt_bindings",
                    technical_details = {
                        cpp_error_code = parsed_error.errorCode,
                        cpp_severity = parsed_error.severity,
                        original_json = error_string
                    },
                    remediation = {
                        "Check C++ Qt function parameters and usage",
                        "Verify widget hierarchy and parenting",
                        "Review Qt documentation for the failing operation"
                    }
                }
            end
        end
        
        -- Standard Lua error occurred
        return error_system.create_error({
            code = ERROR_CODES.LUA_RUNTIME_ERROR,
            category = ERROR_CATEGORIES.LUA_ENGINE,
            severity = ERROR_SEVERITY.ERROR,
            message = "Lua runtime error: " .. tostring(result),
            operation = context.operation or "unknown_function_call",
            component = context.component or "lua_engine",
            technical_details = {
                lua_error = tostring(result),
                function_name = context.function_name or "anonymous"
            },
            remediation = {
                "Check Lua syntax and logic in the failing function",
                "Verify all required parameters are provided",
                "Check that all required Lua modules are loaded"
            }
        })
    end
    
    -- CRITICAL: Validate return type - functions called by safe_call MUST return ErrorContext objects
    if result ~= nil and type(result) ~= "table" then
        error("FATAL: Function " .. (context.operation or "unknown") .. " returned " .. type(result) .. 
              " but safe_call requires ErrorContext table objects. " ..
              "Fix the function to return error_system.create_success() or error_system.create_error(). " ..
              "Function: " .. (context.component or "unknown") .. "." .. (context.operation or "unknown"))
    end
    
    if result ~= nil and type(result) == "table" and result.success == nil then
        error("FATAL: Function " .. (context.operation or "unknown") .. " returned table without .success field. " ..
              "ErrorContext objects must have .success field. " ..
              "Fix the function to return error_system.create_success() or error_system.create_error(). " ..
              "Function: " .. (context.component or "unknown") .. "." .. (context.operation or "unknown"))
    end
    
    if error_system.is_error(result) then
        -- Propagate existing error with added context
        return error_system.add_context(result, context)
    end
    
    -- Success or non-error result
    return result
end

-- Create Qt-specific errors with targeted remediation
function error_system.qt_widget_error(operation, widget_type, details)
    local code_map = {
        create = "QT_WIDGET_CREATE_FAILED",
        style = "QT_WIDGET_STYLE_FAILED", 
        connect = "QT_WIDGET_CONNECTION_FAILED",
        layout = "QT_LAYOUT_FAILED"
    }
    
    local remediation_map = {
        create = {
            "Verify Qt bindings are properly loaded",
            "Check that the parent widget exists and is valid",
            "Ensure sufficient memory is available for widget creation"
        },
        style = {
            "Check Qt stylesheet syntax for errors",
            "Verify widget exists before applying styles",
            "Try simplifying the stylesheet to isolate issues"
        },
        connect = {
            "Verify both widgets exist before connecting",
            "Check that widget IDs are correct and valid",
            "Ensure proper parent-child relationships"
        },
        layout = {
            "Verify parent widget has a layout before adding children",
            "Check that layout type is supported",
            "Ensure widget hasn't already been added to another layout"
        }
    }
    
    return error_system.create_error({
        code = code_map[operation] or "QT_WIDGET_ERROR",
        category = ERROR_CATEGORIES.QT_WIDGET,
        severity = ERROR_SEVERITY.ERROR,
        message = "Qt " .. widget_type .. " " .. operation .. " failed",
        user_message = "Failed to " .. operation .. " " .. widget_type .. " widget in the interface",
        operation = "qt_" .. operation,
        component = "qt_widget_system",
        technical_details = details or {},
        remediation = remediation_map[operation] or {
            "Check Qt system status and try restarting the application"
        }
    })
end

-- Create Inspector-specific errors
function error_system.inspector_error(operation, details)
    local remediation = {
        "Verify metadata schemas are loaded correctly",
        "Check that Qt widgets are available and functional", 
        "Try refreshing the inspector panel",
        "Restart the application if the problem persists"
    }
    
    return error_system.create_error({
        code = "INSPECTOR_" .. string.upper(operation) .. "_FAILED",
        category = ERROR_CATEGORIES.INSPECTOR,
        severity = ERROR_SEVERITY.ERROR,
        message = "Inspector " .. operation .. " failed",
        user_message = "The inspector panel encountered an error during " .. operation,
        operation = "inspector_" .. operation,
        component = "inspector_panel",
        technical_details = details or {},
        remediation = remediation
    })
end

-- Type assertion helper for clean parameter validation
function error_system.assert_type(param, expected_type, param_name, context)
    if type(param) ~= expected_type then
        local error_obj = error_system.create_error({
            message = "Invalid " .. param_name .. " type: " .. type(param) .. ", expected " .. expected_type,
            operation = context.operation,
            component = context.component,
            code = ERROR_CODES.INVALID_PARAMETER_TYPE,
            technical_details = {
                received_type = type(param),
                expected_type = expected_type,
                parameter_name = param_name
            }
        })
        error(error_system.format_user_error(error_obj))
    end
    -- Returns nothing on success (like standard assert)
end

-- Helper function for detailed error logging - handles both error objects and simple values
function error_system.log_detailed_error(obj)
    if error_system.is_error(obj) then
        return error_system.format_debug_error(obj)
    else
        return tostring(obj)
    end
end

-- Export error categories, severity levels, and error codes
error_system.CATEGORIES = ERROR_CATEGORIES
error_system.SEVERITY = ERROR_SEVERITY
error_system.CODES = ERROR_CODES

return error_system