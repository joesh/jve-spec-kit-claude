-- show_prefs_dialog.lua
-- Quick test: shows the preferences panel
-- Run: dofile("scripts/show_prefs_dialog.lua")

local qt = require("bug_reporter.qt_compat")
if not qt.is_available() then
    print("ERROR: Qt bindings not available")
    return
end

local prefs = require("bug_reporter.ui.preferences_panel")
local wrapper = prefs.create()

if wrapper and wrapper.widget then
    print("✓ Preferences panel created")
    -- Wrap in a dialog to show it
    local dialog = qt.CREATE_DIALOG("Bug Reporter Preferences", 500, 600)
    local layout = qt.CREATE_LAYOUT("vertical")
    qt.LAYOUT_ADD_WIDGET(layout, wrapper.widget)
    qt.SET_DIALOG_LAYOUT(dialog, layout)
    qt.SHOW_DIALOG(dialog)
    print("✓ Dialog closed")
else
    print("✗ Failed to create preferences panel")
end
