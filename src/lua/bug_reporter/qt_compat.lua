--- Qt Compatibility Layer for Bug Reporter
-- Maps bug_reporter's expected API to qt_constants bindings
-- This module provides the functions expected by bug_reporter UI code
local M = {}

local qt = nil

--- Initialize with qt_constants
function M.init()
    -- Require qt_constants when first needed (after C++ has initialized it)
    if qt == nil then
        local ok, qt_mod = pcall(require, "core.qt_constants")
        if ok and type(qt_mod) == "table" then
            qt = qt_mod
        else
            qt = false  -- Mark as failed so we don't retry
        end
    end
    return type(qt) == "table"
end

--- Check if Qt is available
function M.is_available()
    if not M.init() then return false end
    return qt.DIALOG and qt.DIALOG.CREATE
end

-- Dialog functions
function M.CREATE_DIALOG(title, width, height)
    if not M.init() then return nil end
    return qt.DIALOG.CREATE(title, width or 400, height or 300)
end

function M.SET_DIALOG_LAYOUT(dialog, layout)
    if not M.init() then return end
    qt.DIALOG.SET_LAYOUT(dialog, layout)
end

function M.SHOW_DIALOG(dialog)
    if not M.init() then return end
    qt.DIALOG.SHOW(dialog)
end

function M.CLOSE_DIALOG(dialog, accept)
    if not M.init() then return end
    qt.DIALOG.CLOSE(dialog, accept)
end

-- Layout functions
function M.CREATE_LAYOUT(direction)
    if not M.init() then return nil end
    if direction == "vertical" then
        return qt.LAYOUT.CREATE_VBOX()
    else
        return qt.LAYOUT.CREATE_HBOX()
    end
end

function M.LAYOUT_ADD_WIDGET(layout, widget)
    if not M.init() then return end
    qt.LAYOUT.ADD_WIDGET(layout, widget)
end

function M.LAYOUT_ADD_STRETCH(layout)
    if not M.init() then return end
    qt.LAYOUT.ADD_STRETCH(layout)
end

function M.LAYOUT_ADD_SPACING(layout, spacing)
    if not M.init() then return end
    qt.LAYOUT.ADD_SPACING(layout, spacing)
end

function M.LAYOUT_ADD_LAYOUT(parent_layout, child_layout)
    if not M.init() then return end
    qt.LAYOUT.ADD_LAYOUT(parent_layout, child_layout)
end

function M.SET_WIDGET_LAYOUT(widget, layout)
    if not M.init() then return end
    qt.LAYOUT.SET_WIDGET_LAYOUT(widget, layout)
end

-- Widget creation functions
function M.CREATE_LABEL(text)
    if not M.init() then return nil end
    return qt.WIDGET.CREATE_LABEL(text)
end

function M.CREATE_BUTTON(text)
    if not M.init() then return nil end
    return qt.WIDGET.CREATE_BUTTON(text)
end

function M.CREATE_CHECKBOX(text)
    if not M.init() then return nil end
    return qt.WIDGET.CREATE_CHECKBOX(text)
end

function M.CREATE_LINE_EDIT(text)
    if not M.init() then return nil end
    return qt.WIDGET.CREATE_LINE_EDIT(text)
end

function M.CREATE_TEXT_EDIT(text)
    if not M.init() then return nil end
    return qt.WIDGET.CREATE_TEXT_EDIT(text)
end

function M.CREATE_COMBOBOX(items)
    if not M.init() then return nil end
    local cb = qt.WIDGET.CREATE_COMBOBOX()
    if cb and items then
        for _, item in ipairs(items) do
            qt.PROPERTIES.ADD_COMBOBOX_ITEM(cb, item)
        end
    end
    return cb
end

function M.CREATE_GROUP_BOX(title)
    if not M.init() then return nil end
    return qt.WIDGET.CREATE_GROUP_BOX(title)
end

function M.CREATE_PROGRESS_BAR()
    if not M.init() then return nil end
    return qt.WIDGET.CREATE_PROGRESS_BAR()
end

function M.CREATE_WIDGET()
    if not M.init() then return nil end
    return qt.WIDGET.CREATE()
end

function M.CREATE_SPINBOX(min, max, default)
    -- Spinbox not yet implemented in C++ bindings
    -- Return nil to signal unavailability
    return nil
end

-- Property setters
function M.SET_WIDGET_STYLE(widget, css)
    if not M.init() then return end
    qt.PROPERTIES.SET_STYLE(widget, css)
end

function M.SET_CHECKED(widget, checked)
    if not M.init() then return end
    qt.PROPERTIES.SET_CHECKED(widget, checked)
end

function M.SET_ENABLED(widget, enabled)
    if not M.init() then return end
    qt.CONTROL.SET_ENABLED(widget, enabled)
end

function M.SET_TEXT(widget, text)
    if not M.init() then return end
    qt.PROPERTIES.SET_TEXT(widget, text)
end

function M.SET_CURRENT_INDEX(widget, index)
    if not M.init() then return end
    qt.PROPERTIES.SET_COMBOBOX_CURRENT_INDEX(widget, index)
end

function M.SET_WIDGET_PROPERTY(widget, prop, value)
    if not M.init() then return end
    -- Map common properties to specific functions
    if prop == "readOnly" then
        qt.CONTROL.SET_TEXT_EDIT_READ_ONLY(widget, value)
    elseif prop == "wordWrap" then
        -- QLabel doesn't have direct binding, use stylesheet workaround
        -- Skip for now
    elseif prop == "placeholderText" then
        qt.PROPERTIES.SET_PLACEHOLDER_TEXT(widget, value)
    elseif prop == "echoMode" then
        -- QLineEdit echo mode not yet implemented, skip
    elseif prop == "minimum" then
        qt.CONTROL.SET_PROGRESS_BAR_RANGE(widget, value, 100)
    elseif prop == "maximum" then
        qt.CONTROL.SET_PROGRESS_BAR_RANGE(widget, 0, value)
    elseif prop == "value" then
        qt.CONTROL.SET_PROGRESS_BAR_VALUE(widget, value)
    elseif prop == "minimumHeight" then
        qt.PROPERTIES.SET_MIN_HEIGHT(widget, value)
    end
end

return M
