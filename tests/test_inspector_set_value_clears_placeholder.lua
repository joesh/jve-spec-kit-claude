#!/usr/bin/env luajit
-- Regression test (retroactive): Entry:set_value clears the "<mixed>"
-- placeholder set by a prior set_mixed(true). Without this, a selection
-- switch from N-clip multi-edit to single-clip single-edit would leave
-- the placeholder visible for any nil-valued field, so the user saw
-- "<mixed>" on fields that should have shown the single clip's real value.
--
-- Reproducer: user had 2 clips selected; Inspector entered multi_edit
-- (fields got placeholder "<mixed>"). User reduced selection to 1 clip;
-- load_single ran set_value(nil) on fields like mark_in (no mark set);
-- widget text was empty but placeholder "<mixed>" still showed.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Record SET_PLACEHOLDER_TEXT / SET_TEXT / SET_STYLE / SET_CHECKED calls
-- on the widget instance.
local widget_placeholder = nil
local widget_text        = nil

package.loaded["core.qt_constants"] = {
    WIDGET     = {
        CREATE_LINE_EDIT = function() return { _kind = "line_edit" } end,
        CREATE           = function() return {} end,
        CREATE_LABEL     = function() return {} end,
        CREATE_CHECKBOX  = function() return {} end,
        CREATE_COMBOBOX  = function() return {} end,
    },
    LAYOUT     = {
        CREATE_HBOX = function() return {} end,
        SET_ON_WIDGET = function() end,
        SET_MARGINS   = function() end,
        SET_SPACING   = function() end,
        ADD_WIDGET    = function() end,
        SET_STRETCH_FACTOR = function() end,
    },
    PROPERTIES = {
        SET_STYLE            = function() end,
        SET_TEXT             = function(_, v) widget_text = v end,
        SET_PLACEHOLDER_TEXT = function(_, v) widget_placeholder = v end,
        SET_ALIGNMENT        = function() end,
        SET_CHECKED          = function() end,
        SET_MIN_HEIGHT       = function() end,
        ADD_COMBOBOX_ITEM    = function() end,
        SET_COMBOBOX_CURRENT_TEXT = function() end,
        GET_TEXT             = function() return widget_text or "" end,
        GET_CHECKED          = function() return false end,
        ALIGN_RIGHT          = "AlignRight",
    },
    DISPLAY    = { SET_VISIBLE = function() end },
    CONTROL    = { SET_LINE_EDIT_READ_ONLY = function() end, SET_ENABLED = function() end },
    GEOMETRY   = { SET_SIZE_POLICY = function() end },
}

package.loaded["core.qt_signals"] = {
    connect       = function() return 1 end,
    onTextChanged = function() return 1 end,
}

local field_widget = require("ui.inspector.field_widget")
local schemas = require("ui.metadata_schemas")

local pass, fail = 0, 0
local function check(label, ok) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end end

print("=== Entry:set_value clears <mixed> placeholder ===\n")

-- Build a STRING field entry.
local entry = field_widget.create_field({}, {
    key   = "name",
    label = "Name",
    type  = schemas.FIELD_TYPES.STRING,
}, {
    frame_rate = function() return { fps_numerator = 25, fps_denominator = 1 } end,
    on_commit  = function() end,
})

-- Initial state.
widget_placeholder = nil; widget_text = nil
entry:set_value("initial")
check("set_value wrote text",               widget_text == "initial")
check("set_value did NOT set a placeholder", widget_placeholder == "" or widget_placeholder == nil)

-- Simulate multi-edit: set placeholder to "<mixed>".
entry:set_mixed(true)
check("set_mixed(true) wrote <mixed> placeholder",
    widget_placeholder == "<mixed>")
check("set_mixed(true) cleared widget text",
    widget_text == "")

-- Now simulate the selection reducing to a single clip with nil value.
-- set_value(nil) must CLEAR the placeholder so it doesn't show through.
entry:set_value(nil)
check("set_value(nil) cleared the <mixed> placeholder",
    widget_placeholder == "")
check("set_value(nil) wrote empty widget text",
    widget_text == "")

-- And set_value with a real value also clears the placeholder.
entry:set_mixed(true)
check("precondition: placeholder reset to <mixed>", widget_placeholder == "<mixed>")
entry:set_value("NewName")
check("set_value(value) cleared placeholder",
    widget_placeholder == "")
check("set_value(value) wrote the real text",
    widget_text == "NewName")
check("set_value clears mixed flag", entry.mixed == false)

-- TIMECODE field: same behavior for nil → format_value("") but placeholder cleared.
local tc_entry = field_widget.create_field({}, {
    key   = "mark_in_frame",
    label = "Mark In",
    type  = schemas.FIELD_TYPES.TIMECODE,
}, {
    frame_rate = function() return { fps_numerator = 25, fps_denominator = 1 } end,
    on_commit  = function() end,
})
widget_placeholder = nil
tc_entry:set_mixed(true)
check("TIMECODE: set_mixed(true) set <mixed> placeholder",
    widget_placeholder == "<mixed>")
tc_entry:set_value(nil)
check("TIMECODE: set_value(nil) cleared <mixed> placeholder",
    widget_placeholder == "")

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_set_value_clears_placeholder.lua passed")
