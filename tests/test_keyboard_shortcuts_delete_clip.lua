#!/usr/bin/env luajit
-- Tests that DeleteSelection command dispatches correctly via TOML keybindings.
-- Delete/Backspace → DeleteSelection; Shift+Delete → DeleteSelection ripple=true.

require('test_env')

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
    get_executor = function(command_name)
        if command_name == "DeleteSelection" then return function() end end
        return nil
    end,
    peek_command_event_origin = function() return nil end,
    begin_command_event = function() end,
    end_command_event = function() end,
}

keyboard_shortcuts.init(nil, mock_command_manager, nil, nil)

local kb = require("core.keyboard_constants")

-- Test 1: Delete key dispatches DeleteSelection
print("\nTest 1: Delete key dispatches DeleteSelection")
captured_commands = {}
keyboard_shortcuts.handle_key({
    key = kb.KEY.Delete,
    modifiers = 0,
    text = "",
    focus_widget_is_text_input = 0,
})
assert(#captured_commands >= 1, "Should dispatch at least one command")
assert(captured_commands[1].name == "DeleteSelection",
    "Should dispatch DeleteSelection, got: " .. tostring(captured_commands[1].name))
print("  ✓ Delete key dispatches DeleteSelection")

-- Test 2: Shift+Delete passes ripple=true
print("\nTest 2: Shift+Delete passes ripple=true")
captured_commands = {}
keyboard_shortcuts.handle_key({
    key = kb.KEY.Delete,
    modifiers = kb.MOD.Shift,
    text = "",
    focus_widget_is_text_input = 0,
})
assert(#captured_commands >= 1, "Should dispatch at least one command")
assert(captured_commands[1].name == "DeleteSelection",
    "Should dispatch DeleteSelection, got: " .. tostring(captured_commands[1].name))
assert(captured_commands[1].params.ripple == true,
    "Shift+Delete should set ripple=true")
print("  ✓ Shift+Delete passes ripple=true")

-- Test 3: Backspace also dispatches DeleteSelection
print("\nTest 3: Backspace dispatches DeleteSelection")
captured_commands = {}
keyboard_shortcuts.handle_key({
    key = kb.KEY.Backspace,
    modifiers = 0,
    text = "",
    focus_widget_is_text_input = 0,
})
assert(#captured_commands >= 1, "Should dispatch at least one command")
assert(captured_commands[1].name == "DeleteSelection",
    "Should dispatch DeleteSelection, got: " .. tostring(captured_commands[1].name))
print("  ✓ Backspace dispatches DeleteSelection")

print("\n✅ test_keyboard_shortcuts_delete_clip.lua passed")
