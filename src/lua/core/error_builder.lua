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
-- Size: ~162 LOC
-- Volatility: unknown
--
-- @file error_builder.lua
-- Original intent (unreviewed):
-- Error Builder - Fluent interface for constructing rich error contexts
-- Inspired by C++ ErrorContext::Builder but designed for Lua idioms
-- Provides method chaining and automatic context accumulation
local error_system = require("core.error_system")

local ErrorBuilder = {}
ErrorBuilder.__index = ErrorBuilder

-- Create a new error builder
-- severity: string - "critical", "error", "warning", "info"
-- code: string - error code from error_system.CODES
-- message: string - base error message
function ErrorBuilder.new(severity, code, message)
    local self = setmetatable({}, ErrorBuilder)
    
    self.error_data = {
        severity = severity,
        code = code,
        message = message,
        category = "general",
        operation = "unknown",
        component = "unknown",
        user_message = message,
        technical_details = {},
        context = {},
        suggestions = {},
        auto_fixes = {},
        attempted_actions = {},
        timestamp = os.time()
    }
    
    return self
end

-- Add contextual information
-- key: string - context key
-- value: any - context value (will be converted to string)
function ErrorBuilder:addContext(key, value)
    self.error_data.context[key] = tostring(value)
    return self -- Enable method chaining
end

-- Add multiple context items at once
-- context_table: table - key-value pairs to add as context
function ErrorBuilder:addContextTable(context_table)
    if type(context_table) == "table" then
        for key, value in pairs(context_table) do
            self.error_data.context[key] = tostring(value)
        end
    end
    return self
end

-- Add a remediation suggestion
-- suggestion: string - what the user should do to fix this
function ErrorBuilder:addSuggestion(suggestion)
    table.insert(self.error_data.suggestions, suggestion)
    return self
end

-- Add multiple suggestions at once
-- suggestions: table - array of suggestion strings
function ErrorBuilder:addSuggestions(suggestions)
    if type(suggestions) == "table" then
        for _, suggestion in ipairs(suggestions) do
            table.insert(self.error_data.suggestions, suggestion)
        end
    end
    return self
end

-- Add an automatic fix option
-- description: string - what the fix does
-- code_hint: string - code or command to execute the fix
-- confidence: number (0-100) - how confident we are this will work
function ErrorBuilder:addAutoFix(description, code_hint, confidence)
    confidence = confidence or 50
    table.insert(self.error_data.auto_fixes, {
        description = description,
        code_hint = code_hint,
        confidence = confidence
    })
    return self
end

-- Record an action that was attempted before this error
-- action: string - description of what was tried
function ErrorBuilder:withAttemptedAction(action)
    table.insert(self.error_data.attempted_actions, action)
    return self
end

-- Set the operation context
-- operation: string - name of the operation that failed
function ErrorBuilder:withOperation(operation)
    self.error_data.operation = operation
    return self
end

-- Set the component context
-- component: string - name of the component that failed
function ErrorBuilder:withComponent(component)
    self.error_data.component = component
    return self
end

-- Set the error category
-- category: string - error category from error_system categories
function ErrorBuilder:withCategory(category)
    self.error_data.category = category
    return self
end

-- Set user-facing message (different from technical message)
-- user_message: string - what to show to the end user
function ErrorBuilder:withUserMessage(user_message)
    self.error_data.user_message = user_message
    return self
end

-- Add technical details for debugging
-- details: table - technical information for developers
function ErrorBuilder:withTechnicalDetails(details)
    if type(details) == "table" then
        for key, value in pairs(details) do
            self.error_data.technical_details[key] = value
        end
    end
    return self
end

-- Escalate error severity
-- new_severity: string - higher severity level
function ErrorBuilder:escalate(new_severity)
    local severity_levels = {info = 1, warning = 2, error = 3, critical = 4}
    local current_level = severity_levels[self.error_data.severity] or 1
    local new_level = severity_levels[new_severity] or 1
    
    if new_level > current_level then
        self.error_data.severity = new_severity
    end
    return self
end

-- Add Qt widget context (if widget is available)
-- widget: userdata - Qt widget that caused the error
function ErrorBuilder:withQtWidget(widget)
    if widget then
        self:addContext("widget_type", type(widget))
        self:addContext("widget_address", tostring(widget))
        
        -- Try to get widget class name if available
        local qt_constants = require("core.qt_constants")
        local success, class_name = pcall(qt_constants.WIDGET.GET_CLASS_NAME, widget)
        if success and class_name then
            self:addContext("widget_class", class_name)
        end
    end
    return self
end

-- Add timing context for performance analysis
-- start_value: number - when operation started (from os.time() or os.clock())
function ErrorBuilder:withTiming(start_value)
    if start_value then
        local duration = os.time() - start_value
        self:addContext("operation_duration_seconds", duration)
    end
    return self
end

-- Build the final error object
-- Returns: error object compatible with error_system
function ErrorBuilder:build()
    -- Enhance with automatic suggestions based on error patterns
    self:_addAutomaticSuggestions()
    
    -- Map internal fields to error_system compatibility
    self.error_data.remediation = self.error_data.suggestions
    -- Merge context into technical_details (don't overwrite existing details)
    for key, value in pairs(self.error_data.context) do
        if self.error_data.technical_details[key] == nil then
            self.error_data.technical_details[key] = value
        end
    end
    
    -- Build final error using existing error_system
    return error_system.create_error(self.error_data)
end

-- Private: Add automatic suggestions based on error patterns
function ErrorBuilder:_addAutomaticSuggestions()
    local message = self.error_data.message:lower()
    local code = self.error_data.code
    
    -- Widget creation failures
    if string.find(message, "widget.*creation") or string.find(message, "failed.*create") then
        self:addSuggestion("Check that Qt bindings are properly loaded")
        self:addSuggestion("Verify widget parameters are valid")
        self:addAutoFix("Retry widget creation with default parameters", "widget = qt.create_widget(default_params)", 60)
    end
    
    -- Layout failures
    if string.find(message, "layout") then
        self:addSuggestion("Ensure parent widget exists before setting layout")
        self:addSuggestion("Check that layout parameters are valid")
        self:addAutoFix("Create layout with minimal parameters", "layout = qt.create_layout()", 70)
    end
    
    -- Signal/callback failures  
    if string.find(message, "signal") or string.find(message, "callback") or string.find(message, "handler") then
        self:addSuggestion("Verify signal name is correct for widget type")
        self:addSuggestion("Check that handler function exists and is callable")
        self:addAutoFix("Use qt_signals.connect() instead of direct Qt binding", "qt_signals.connect(widget, signal, handler)", 80)
    end
    
    -- Missing function/method errors
    if string.find(message, "nil.*function") or string.find(message, "attempt.*call") then
        self:addSuggestion("Check that required modules are loaded")
        self:addSuggestion("Verify function name spelling")
        self:addAutoFix("Check module loading", "require('missing_module')", 50)
    end
end

-- Convenience constructors for common error types

function ErrorBuilder.createWidgetError(message)
    return ErrorBuilder.new("error", "WIDGET_ERROR", message)
        :withCategory("qt_widget")
        :withComponent("widget_system")
end

function ErrorBuilder.createLayoutError(message)
    return ErrorBuilder.new("error", "LAYOUT_ERROR", message)
        :withCategory("qt_layout")
        :withComponent("layout_system")
end

function ErrorBuilder.createSignalError(message)
    return ErrorBuilder.new("error", "SIGNAL_ERROR", message)
        :withCategory("signals")
        :withComponent("signal_system")
end

function ErrorBuilder.createValidationError(message)
    return ErrorBuilder.new("error", "VALIDATION_ERROR", message)
        :withCategory("validation")
        :withComponent("input_validation")
end

return ErrorBuilder