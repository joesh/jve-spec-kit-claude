#!/usr/bin/env luajit
-- Regression tests (TDD red → green):
--
-- (1) A read_only BOOLEAN checkbox MUST NOT respond to user clicks (currently
--     the "offline" field can be toggled in the Inspector even though the
--     schema says it's read-only).
-- (2) Tab navigation MUST skip read-only fields (currently Tab lands on
--     read-only QLineEdits because their default StrongFocus policy still
--     accepts tab focus).
--
-- Both are enforced at widget-construction time: read-only fields get
-- setEnabled(false) for BOOLEAN (prevents click) and setFocusPolicy("NoFocus")
-- for all read-only widgets (prevents tab stop). Non-read-only widgets are
-- untouched.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Capture SET_ENABLED + set_focus_policy calls keyed by widget identity.
-- Each test case clears these before running; the variables persist so
-- the closures below have a stable target.
local enabled_state    = {}
local focus_policy_set = {}
local function clear(t) for k in pairs(t) do t[k] = nil end end

package.loaded["core.qt_constants"] = {
    WIDGET = {
        CREATE           = function() return {} end,
        CREATE_LINE_EDIT = function() return { _kind = "line_edit" } end,
        CREATE_LABEL     = function() return {} end,
        CREATE_CHECKBOX  = function() return { _kind = "checkbox" } end,
        CREATE_COMBOBOX  = function() return {} end,
    },
    LAYOUT = {
        CREATE_HBOX = function() return {} end,
        SET_ON_WIDGET = function() end, SET_MARGINS = function() end,
        SET_SPACING = function() end, ADD_WIDGET = function() end,
        SET_STRETCH_FACTOR = function() end,
    },
    PROPERTIES = {
        SET_STYLE = function() end, SET_TEXT = function() end,
        SET_PLACEHOLDER_TEXT = function() end, SET_ALIGNMENT = function() end,
        SET_CHECKED = function() end, SET_MIN_HEIGHT = function() end,
        GET_TEXT = function() return "" end, GET_CHECKED = function() return false end,
        ADD_COMBOBOX_ITEM = function() end, SET_COMBOBOX_CURRENT_TEXT = function() end,
        ALIGN_RIGHT = "AlignRight",
    },
    DISPLAY  = { SET_VISIBLE = function() end },
    CONTROL  = {
        SET_LINE_EDIT_READ_ONLY = function() end,
        SET_ENABLED = function(w, v) enabled_state[w] = v end,
    },
    GEOMETRY = { SET_SIZE_POLICY = function() end },
}
package.loaded["core.qt_signals"] = {
    connect = function() return 1 end, onTextChanged = function() return 1 end,
}

-- qt_set_focus_policy is a global binding — stub it.
_G.qt_set_focus_policy = function(widget, policy) focus_policy_set[widget] = policy end

local field_widget = require("ui.inspector.field_widget")
local schemas = require("ui.metadata_schemas")

local pass, fail = 0, 0
local function check(label, ok) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end end

print("=== Inspector: read-only widget state (disable + NoFocus) ===\n")

-- (a) BOOLEAN read_only → checkbox disabled (click rejected at Qt level) AND NoFocus.
do
    clear(enabled_state); clear(focus_policy_set)
    local entry = field_widget.create_field({}, {
        key = "offline", label = "Offline",
        type = schemas.FIELD_TYPES.BOOLEAN, read_only = true,
    }, { sequence = function() return nil end, on_commit = function() end })
    check("BOOLEAN read_only: widget setEnabled(false)",
        enabled_state[entry.widget] == false)
    check("BOOLEAN read_only: widget focusPolicy = NoFocus (Tab skips)",
        focus_policy_set[entry.widget] == "NoFocus")
end

-- (b) BOOLEAN editable → neither disabled nor NoFocus.
do
    clear(enabled_state); clear(focus_policy_set)
    local entry = field_widget.create_field({}, {
        key = "enabled", label = "Enabled",
        type = schemas.FIELD_TYPES.BOOLEAN,  -- read_only defaults false
    }, { sequence = function() return nil end, on_commit = function() end })
    check("BOOLEAN editable: not disabled",
        enabled_state[entry.widget] ~= false)
    check("BOOLEAN editable: focusPolicy not set to NoFocus",
        focus_policy_set[entry.widget] ~= "NoFocus")
end

-- (c) STRING read_only → line edit kept visually editable-looking (NOT disabled)
--     but NoFocus so Tab skips. This is the correct NLE UX: read-only fields
--     display their value in normal text style, but aren't focus stops.
do
    clear(enabled_state); clear(focus_policy_set)
    local entry = field_widget.create_field({}, {
        key = "media_id", label = "Media ID",
        type = schemas.FIELD_TYPES.STRING, read_only = true,
    }, { sequence = function() return nil end, on_commit = function() end })
    check("STRING read_only: focusPolicy = NoFocus",
        focus_policy_set[entry.widget] == "NoFocus")
    -- We intentionally do NOT setEnabled(false) on line edits — it makes them
    -- look grey/disabled. Read-only styling is carried by the stylesheet and
    -- SET_LINE_EDIT_READ_ONLY.
    check("STRING read_only: NOT setEnabled(false) (preserves text-readable look)",
        enabled_state[entry.widget] == nil)
end

-- (d) STRING editable → neither disabled nor NoFocus.
do
    clear(enabled_state); clear(focus_policy_set)
    local entry = field_widget.create_field({}, {
        key = "name", label = "Clip Name",
        type = schemas.FIELD_TYPES.STRING,
    }, { sequence = function() return nil end, on_commit = function() end })
    check("STRING editable: not disabled",
        enabled_state[entry.widget] ~= false)
    check("STRING editable: focusPolicy not NoFocus",
        focus_policy_set[entry.widget] ~= "NoFocus")
end

-- (e) TIMECODE read_only (e.g. playhead_frame) → NoFocus, kept enabled.
do
    clear(enabled_state); clear(focus_policy_set)
    local entry = field_widget.create_field({}, {
        key = "playhead_frame", label = "Source Playhead",
        type = schemas.FIELD_TYPES.TIMECODE, read_only = true,
    }, { sequence = function() return { frame_rate = { fps_numerator = 25, fps_denominator = 1 }, start_timecode_frame = 0 } end, on_commit = function() end })
    check("TIMECODE read_only: focusPolicy = NoFocus",
        focus_policy_set[entry.widget] == "NoFocus")
    check("TIMECODE read_only: NOT disabled",
        enabled_state[entry.widget] == nil)
end

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_read_only_widget_state.lua passed")
