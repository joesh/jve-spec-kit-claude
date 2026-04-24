#!/usr/bin/env luajit
-- The Inspector's QScrollArea must not accept keyboard focus. Default
-- Qt is StrongFocus, which would put the area in the Tab chain between
-- search and the first field. Verified by observing the policy call
-- made during mount.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local function tagged(kind)
    return setmetatable({ _kind = kind }, { __tostring = function() return kind end })
end

local scroll_area_token = tagged("scroll_area")
local scroll_area_policy = nil

_G.qt_set_focus_policy = function(widget, policy)
    if widget == scroll_area_token then scroll_area_policy = policy end
end
_G.qt_set_line_edit_text_changed_handler = function() end
_G.qt_set_focus_handler = function() end

package.loaded["core.qt_constants"] = {
    WIDGET = {
        CREATE             = function() return tagged("plain") end,
        CREATE_LABEL       = function() return tagged("label") end,
        CREATE_LINE_EDIT   = function() return tagged("line_edit") end,
        CREATE_BUTTON      = function() return tagged("button") end,
        CREATE_SCROLL_AREA = function() return scroll_area_token end,
        CREATE_CHECKBOX    = function() return tagged("checkbox") end,
        CREATE_COMBOBOX    = function() return tagged("combobox") end,
    },
    LAYOUT = {
        CREATE_VBOX        = function() return tagged("vbox") end,
        CREATE_HBOX        = function() return tagged("hbox") end,
        SET_ON_WIDGET      = function() end,
        SET_MARGINS        = function() end,
        SET_SPACING        = function() end,
        ADD_WIDGET         = function() end,
        ADD_STRETCH        = function() end,
        SET_STRETCH_FACTOR = function() end,
    },
    PROPERTIES = {
        SET_STYLE            = function() end,
        SET_TEXT             = function() end,
        SET_PLACEHOLDER_TEXT = function() end,
        SET_ALIGNMENT        = function() end,
        SET_CHECKED          = function() end,
        SET_MIN_HEIGHT       = function() end,
        ADD_COMBOBOX_ITEM    = function() end,
        SET_COMBOBOX_CURRENT_TEXT = function() end,
        GET_TEXT             = function() return "" end,
        GET_CHECKED          = function() return false end,
        ALIGN_RIGHT          = "AlignRight",
    },
    DISPLAY = { SET_VISIBLE = function() end, SHOW = function() end },
    CONTROL = {
        SET_LINE_EDIT_READ_ONLY = function() end,
        SET_ENABLED             = function() end,
        SET_SCROLL_AREA_WIDGET  = function() end,
    },
    GEOMETRY = { SET_SIZE_POLICY = function() end },
}

package.loaded["core.qt_signals"] = {
    connect       = function() return 1 end,
    onTextChanged = function() return 1 end,
}

package.loaded["ui.timeline.timeline_state"] = {
    get_sequence_frame_rate = function() return { fps_numerator = 24, fps_denominator = 1 } end,
}

package.loaded["core.signals"] = {
    connect    = function() return 1 end,
    disconnect = function() end,
    emit       = function() end,
}

package.loaded["core.persistent_widget"] = {
    get = function(_k, default) return default end,
    set = function() end,
}

print("=== Inspector scroll area: NoFocus policy installed ===\n")

package.loaded["ui.inspector.mount"] = nil
require("ui.inspector.mount").mount(tagged("container"))

assert(scroll_area_policy == "NoFocus", string.format(
    "expected NoFocus on scroll area, got %q", tostring(scroll_area_policy)))

print("✅ test_inspector_scroll_area_no_focus.lua passed")
