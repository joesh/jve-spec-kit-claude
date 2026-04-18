#!/usr/bin/env luajit

-- Menu action dispatch: all commands route through execute_interactive except
-- Insert/Overwrite (need project_browser context) and Quit.

require("test_env")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

print("\n=== Menu action dispatch table ===")

-- Stub command_manager
local executed_commands = {}
local mock_cm = {
    execute = function(cmd_name, params)
        table.insert(executed_commands, cmd_name)
        return { success = true }
    end,
    execute_interactive = function(cmd_name, params)
        table.insert(executed_commands, cmd_name)
        return { success = true }
    end,
    can_undo = function() return true end,
    can_redo = function() return true end,
    undo = function() end,
    redo = function() end,
    add_listener = function() return function() end end,
    remove_listener = function() end,
}

-- Stub lxp (XML parser, not available in test env)
package.loaded["lxp"] = { new = function() return {} end }

-- Stub qt_constants (not available in test env)
local noop = function() end
_G.qt_constants = {
    MENU = {
        GET_MENU_BAR = noop,
        CREATE_MENU = noop,
        ADD_MENU_TO_BAR = noop,
        ADD_SUBMENU = noop,
        CREATE_MENU_ACTION = noop,
        CONNECT_MENU_ACTION = noop,
        ADD_MENU_SEPARATOR = noop,
        SET_ACTION_ENABLED = noop,
    },
}

-- Stub database.get_current_project_id (no DB in test)
local db_mod = require("core.database")
db_mod.get_current_project_id = function() return "test_proj" end

local menu_system = require("core.menu_system")
menu_system.init(nil, mock_cm)

-- ─── Test 1: "Undo" → dispatches through execute_interactive ───
print("\n--- Undo → execute_interactive ---")
do
    executed_commands = {}
    local cb = menu_system._test_get_action_callback("Undo")
    cb()
    check("Undo dispatched via execute_interactive", #executed_commands == 1)
    check("Correct command name", executed_commands[1] == "Undo")
end

-- ─── Test 2: "Redo" → dispatches through execute_interactive ───
print("\n--- Redo → execute_interactive ---")
do
    executed_commands = {}
    local cb = menu_system._test_get_action_callback("Redo")
    cb()
    check("Redo dispatched via execute_interactive", #executed_commands == 1)
    check("Correct command name", executed_commands[1] == "Redo")
end

-- ─── Test 3: "DeleteSelection" → dispatches through execute_interactive ───
print("\n--- DeleteSelection → execute_interactive ---")
do
    executed_commands = {}
    local cb = menu_system._test_get_action_callback("DeleteSelection")
    cb()
    check("DeleteSelection dispatched via execute_interactive", #executed_commands == 1)
    check("Correct command name", executed_commands[1] == "DeleteSelection")
end

-- ─── Test 4: Unknown command → falls through to execute_interactive ───
print("\n--- Unknown → execute_interactive ---")
do
    executed_commands = {}
    local cb = menu_system._test_get_action_callback("SomeOtherCommand")
    cb()
    check("Unknown command → execute_interactive called", #executed_commands == 1)
    check("Correct command name passed", executed_commands[1] == "SomeOtherCommand")
end

-- ─── Test 5: Insert menu → execute_interactive (no special case) ───
print("\n--- Insert → execute_interactive (pure command dispatch) ---")
do
    executed_commands = {}
    local cb = menu_system._test_get_action_callback("Insert")
    cb()
    check("Insert dispatched via execute_interactive", #executed_commands == 1)
    check("Insert command name correct", executed_commands[1] == "Insert")
end

-- ─── Test 6: Overwrite menu → execute_interactive (no special case) ───
print("\n--- Overwrite → execute_interactive (pure command dispatch) ---")
do
    executed_commands = {}
    local cb = menu_system._test_get_action_callback("Overwrite")
    cb()
    check("Overwrite dispatched via execute_interactive", #executed_commands == 1)
    check("Overwrite command name correct", executed_commands[1] == "Overwrite")
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_menu_action_dispatch.lua passed")
