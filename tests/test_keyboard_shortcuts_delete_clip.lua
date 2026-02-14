#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua"

-- Tests that perform_delete_action dispatches DeleteSelection command
-- After refactor: perform_delete_action is a thin wrapper that delegates
-- to execute_command("DeleteSelection", params)

package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "timeline" end,
    focus_panel = function() return true end,
    set_focused_panel = function() end,
}

local keyboard_shortcuts = require("core.keyboard_shortcuts")

local captured_commands = {}
local mock_command_manager = {
    execute_ui = function(command_name, params)
        captured_commands[#captured_commands + 1] = {
            name = command_name,
            params = params or {},
        }
        return { success = true }
    end,
    peek_command_event_origin = function() return nil end,
    begin_command_event = function() end,
    end_command_event = function() end,
}

keyboard_shortcuts.init(nil, mock_command_manager, nil, nil)

-- Test 1: perform_delete_action dispatches DeleteSelection
captured_commands = {}
assert(keyboard_shortcuts.perform_delete_action({}), "Delete action should be handled")
assert(#captured_commands == 1, "Should dispatch exactly one command")
assert(captured_commands[1].name == "DeleteSelection",
    "Should dispatch DeleteSelection, got: " .. tostring(captured_commands[1].name))
print("  ✓ perform_delete_action dispatches DeleteSelection")

-- Test 2: shift option passes ripple=true
captured_commands = {}
keyboard_shortcuts.perform_delete_action({ shift = true })
assert(#captured_commands == 1, "Should dispatch exactly one command")
assert(captured_commands[1].params.ripple == true,
    "Shift should set ripple=true")
print("  ✓ perform_delete_action with shift passes ripple=true")

-- Test 3: no shift means no ripple param
captured_commands = {}
keyboard_shortcuts.perform_delete_action({})
assert(captured_commands[1].params.ripple == nil,
    "Without shift, ripple should be nil")
print("  ✓ perform_delete_action without shift has no ripple param")

print("✅ test_keyboard_shortcuts_delete_clip.lua passed")
