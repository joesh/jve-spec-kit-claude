#!/usr/bin/env luajit

-- Regression: B2 — Menu action "Delete" must dispatch to perform_delete_action,
-- not try to execute a nonexistent "Delete" command via command_manager.

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

print("\n=== B2: Menu action dispatch table ===")

-- Stub keyboard_shortcuts.perform_delete_action
local delete_call_count = 0
package.loaded["core.keyboard_shortcuts"] = {
    perform_delete_action = function(_opts)
        delete_call_count = delete_call_count + 1
        return true
    end,
}

-- Stub command_manager
local executed_commands = {}
local mock_cm = {
    execute = function(cmd_name, params)
        table.insert(executed_commands, cmd_name)
        return { success = true }
    end,
    execute_ui = function(cmd_name, params)
        table.insert(executed_commands, cmd_name)
        return { success = true }
    end,
    can_undo = function() return true end,
    can_redo = function() return true end,
    undo = function() end,
    redo = function() end,
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

-- ─── Test 1: "Delete" → dispatches to perform_delete_action ───
print("\n--- Delete → perform_delete_action ---")
do
    local before = delete_call_count
    local cb = menu_system._test_get_action_callback("Delete")
    cb()
    check("Delete dispatched to keyboard_shortcuts", delete_call_count > before)
    check("Delete NOT sent to command_manager", #executed_commands == 0)
end

-- ─── Test 2: "Undo" still works via dispatch table ───
print("\n--- Undo → command_manager.undo ---")
do
    local undo_called = false
    mock_cm.undo = function() undo_called = true end
    local cb = menu_system._test_get_action_callback("Undo")
    cb()
    check("Undo dispatched correctly", undo_called)
end

-- ─── Test 3: Unknown command → falls through to command_manager ───
print("\n--- Unknown → command_manager.execute ---")
do
    executed_commands = {}
    local cb = menu_system._test_get_action_callback("SomeOtherCommand")
    cb()
    check("Unknown command → execute_ui called", #executed_commands == 1)
    check("Correct command name passed", executed_commands[1] == "SomeOtherCommand")
end

-- ─── Test 4: Insert menu → project_browser, NOT raw command ───
print("\n--- Insert → project_browser.add_selected_to_timeline ---")
do
    local insert_called_with = nil
    package.loaded["ui.project_browser"] = {
        add_selected_to_timeline = function(cmd_type, opts)
            insert_called_with = cmd_type
        end,
    }
    executed_commands = {}
    local cb = menu_system._test_get_action_callback("Insert")
    cb()
    check("Insert routed to project_browser", insert_called_with == "Insert")
    check("Insert NOT sent to raw command", #executed_commands == 0)
end

-- ─── Test 5: Overwrite menu → project_browser, NOT raw command ───
print("\n--- Overwrite → project_browser.add_selected_to_timeline ---")
do
    local overwrite_called_with = nil
    package.loaded["ui.project_browser"] = {
        add_selected_to_timeline = function(cmd_type, opts)
            overwrite_called_with = cmd_type
        end,
    }
    executed_commands = {}
    local cb = menu_system._test_get_action_callback("Overwrite")
    cb()
    check("Overwrite routed to project_browser", overwrite_called_with == "Overwrite")
    check("Overwrite NOT sent to raw command", #executed_commands == 0)
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_menu_action_dispatch.lua passed")
