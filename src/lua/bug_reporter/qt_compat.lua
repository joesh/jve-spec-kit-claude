--- Qt Compatibility Layer for Bug Reporter
-- Maps bug_reporter's expected API to qt_constants bindings. All
-- operations fail loud when qt_constants is unavailable (Constitution
-- 1.14): a missing C++ binding under a Lua test stub used to silently
-- no-op, which masked real breakage. Tests that don't run under the
-- live binary MUST stub qt_constants explicitly (see tests/test_env.lua).

local M = {}

local qt = nil

--- Initialize with qt_constants. Caches `qt` on first call. Asserting
-- callers (everything below) invoke this through `require_qt(fn)` so
-- the failure message names the bug_reporter API that triggered it.
function M.init()
    if qt == nil then
        local ok, qt_mod = pcall(require, "core.qt_constants")
        if ok and type(qt_mod) == "table" then
            qt = qt_mod
        else
            qt = false
        end
    end
    return type(qt) == "table"
end

local function require_qt(fn_name)
    assert(M.init(),
        "qt_compat." .. fn_name .. ": core.qt_constants not loaded — " ..
        "this code path needs the live C++ bindings or an explicit test stub")
end

--- Check if Qt is available (predicate; does NOT assert).
function M.is_available()
    if not M.init() then return false end
    return qt.DIALOG and qt.DIALOG.CREATE
end

-- Dialog functions
function M.CREATE_DIALOG(title, width, height)
    require_qt("CREATE_DIALOG")
    return qt.DIALOG.CREATE(title, width or 400, height or 300)
end

function M.SET_DIALOG_LAYOUT(dialog, layout)
    require_qt("SET_DIALOG_LAYOUT")
    qt.DIALOG.SET_LAYOUT(dialog, layout)
end

function M.SHOW_DIALOG(dialog)
    require_qt("SHOW_DIALOG")
    qt.DIALOG.SHOW(dialog)
end

function M.CLOSE_DIALOG(dialog, accept)
    require_qt("CLOSE_DIALOG")
    qt.DIALOG.CLOSE(dialog, accept)
end

-- Layout functions
function M.CREATE_LAYOUT(direction)
    require_qt("CREATE_LAYOUT")
    if direction == "vertical" then
        return qt.LAYOUT.CREATE_VBOX()
    else
        return qt.LAYOUT.CREATE_HBOX()
    end
end

function M.LAYOUT_ADD_WIDGET(layout, widget)
    require_qt("LAYOUT_ADD_WIDGET")
    qt.LAYOUT.ADD_WIDGET(layout, widget)
end

function M.LAYOUT_ADD_STRETCH(layout)
    require_qt("LAYOUT_ADD_STRETCH")
    qt.LAYOUT.ADD_STRETCH(layout)
end

function M.LAYOUT_ADD_SPACING(layout, spacing)
    require_qt("LAYOUT_ADD_SPACING")
    qt.LAYOUT.ADD_SPACING(layout, spacing)
end

function M.LAYOUT_ADD_LAYOUT(parent_layout, child_layout)
    require_qt("LAYOUT_ADD_LAYOUT")
    qt.LAYOUT.ADD_LAYOUT(parent_layout, child_layout)
end

function M.SET_WIDGET_LAYOUT(widget, layout)
    require_qt("SET_WIDGET_LAYOUT")
    qt.LAYOUT.SET_WIDGET_LAYOUT(widget, layout)
end

-- Widget creation functions
function M.CREATE_LABEL(text)
    require_qt("CREATE_LABEL")
    return qt.WIDGET.CREATE_LABEL(text)
end

function M.CREATE_BUTTON(text)
    require_qt("CREATE_BUTTON")
    return qt.WIDGET.CREATE_BUTTON(text)
end

function M.CREATE_CHECKBOX(text)
    require_qt("CREATE_CHECKBOX")
    return qt.WIDGET.CREATE_CHECKBOX(text)
end

function M.CREATE_LINE_EDIT(text)
    require_qt("CREATE_LINE_EDIT")
    return qt.WIDGET.CREATE_LINE_EDIT(text)
end

function M.CREATE_TEXT_EDIT(text)
    require_qt("CREATE_TEXT_EDIT")
    return qt.WIDGET.CREATE_TEXT_EDIT(text)
end

function M.CREATE_COMBOBOX(items)
    require_qt("CREATE_COMBOBOX")
    local cb = qt.WIDGET.CREATE_COMBOBOX()
    assert(cb, "qt_compat.CREATE_COMBOBOX: WIDGET.CREATE_COMBOBOX returned nil")
    if items then
        for _, item in ipairs(items) do
            qt.PROPERTIES.ADD_COMBOBOX_ITEM(cb, item)
        end
    end
    return cb
end

function M.CREATE_GROUP_BOX(title)
    require_qt("CREATE_GROUP_BOX")
    return qt.WIDGET.CREATE_GROUP_BOX(title)
end

function M.CREATE_PROGRESS_BAR()
    require_qt("CREATE_PROGRESS_BAR")
    return qt.WIDGET.CREATE_PROGRESS_BAR()
end

function M.CREATE_WIDGET()
    require_qt("CREATE_WIDGET")
    return qt.WIDGET.CREATE()
end

-- Property setters
function M.SET_WIDGET_STYLE(widget, css)
    require_qt("SET_WIDGET_STYLE")
    qt.PROPERTIES.SET_STYLE(widget, css)
end

function M.SET_CHECKED(widget, checked)
    require_qt("SET_CHECKED")
    qt.PROPERTIES.SET_CHECKED(widget, checked)
end

function M.SET_ENABLED(widget, enabled)
    require_qt("SET_ENABLED")
    qt.CONTROL.SET_ENABLED(widget, enabled)
end

function M.SET_TEXT(widget, text)
    require_qt("SET_TEXT")
    qt.PROPERTIES.SET_TEXT(widget, text)
end

function M.GET_TEXT(widget)
    require_qt("GET_TEXT")
    return qt.PROPERTIES.GET_TEXT(widget)
end

function M.GET_CHECKED(widget)
    require_qt("GET_CHECKED")
    return qt.PROPERTIES.GET_CHECKED(widget)
end

function M.SET_CURRENT_INDEX(widget, index)
    require_qt("SET_CURRENT_INDEX")
    qt.PROPERTIES.SET_COMBOBOX_CURRENT_INDEX(widget, index)
end

-- Property bridge: maps Qt-style property names to the targeted setter
-- on qt_constants. Unknown/no-op properties (echoMode, wordWrap) used
-- to silently swallow; now they assert so a caller can't quietly bind
-- a property that does nothing.
function M.SET_WIDGET_PROPERTY(widget, prop, value)
    require_qt("SET_WIDGET_PROPERTY")
    if prop == "readOnly" then
        qt.CONTROL.SET_TEXT_EDIT_READ_ONLY(widget, value)
    elseif prop == "placeholderText" then
        qt.PROPERTIES.SET_PLACEHOLDER_TEXT(widget, value)
    elseif prop == "minimum" then
        qt.CONTROL.SET_PROGRESS_BAR_RANGE(widget, value, 100)
    elseif prop == "maximum" then
        qt.CONTROL.SET_PROGRESS_BAR_RANGE(widget, 0, value)
    elseif prop == "value" then
        qt.CONTROL.SET_PROGRESS_BAR_VALUE(widget, value)
    elseif prop == "minimumHeight" then
        qt.PROPERTIES.SET_MIN_HEIGHT(widget, value)
    else
        error("qt_compat.SET_WIDGET_PROPERTY: unsupported property '" .. tostring(prop) ..
            "' — extend qt_compat.lua or use a typed setter instead of generic property bridge")
    end
end

return M
