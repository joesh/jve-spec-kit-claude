#!/usr/bin/env luajit

-- Regression: menu action callbacks must not cache project_id in closure params.
-- After switching projects, a previously-invoked menu callback must pick up the
-- NEW active project_id, not the one from the first invocation.

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

print("\n=== Menu callback project_id staleness ===")

-- Track what execute_ui receives
local last_params
local mock_cm = {
    execute = function(cmd_name, params)
        last_params = params
        return { success = true }
    end,
    execute_ui = function(cmd_name, params)
        last_params = params
        return { success = true }
    end,
    can_undo = function() return true end,
    can_redo = function() return true end,
    undo = function() end,
    redo = function() end,
    add_listener = function() return function() end end,
    remove_listener = function() end,
}

-- Stub lxp
package.loaded["lxp"] = { new = function() return {} end }

-- Active project_id (switchable)
local current_project_id = "project_A"

-- Stub qt_constants
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

-- Stub ui_state to return our switchable project_id
package.loaded["ui.ui_state"] = {
    get_timeline_panel = function()
        return {
            get_state = function()
                return {
                    get_project_id = function()
                        return current_project_id
                    end,
                }
            end,
        }
    end,
}

local db_mod = require("core.database")
db_mod.get_current_project_id = function() return current_project_id end

local menu_system = require("core.menu_system")
menu_system.init(nil, mock_cm)

-- ─── Test 1: callback with empty params table (like XML menu items) ───
print("\n--- Params table not mutated across project switch ---")
do
    local cb = menu_system._test_get_action_callback("SomeCommand", {})

    -- First call with project A
    last_params = nil
    cb()
    check("First call gets project_A", last_params and last_params.project_id == "project_A")

    -- Switch project
    current_project_id = "project_B"

    -- Second call should get project_B, not stale project_A
    last_params = nil
    cb()
    check("After switch, callback gets project_B", last_params and last_params.project_id == "project_B")
end

-- ─── Test 2: callback with nil params (no params from XML) ───
print("\n--- Nil params also picks up new project ---")
do
    current_project_id = "project_C"
    local cb = menu_system._test_get_action_callback("AnotherCommand")

    last_params = nil
    cb()
    check("Nil params gets project_C", last_params and last_params.project_id == "project_C")

    current_project_id = "project_D"

    last_params = nil
    cb()
    check("Nil params gets project_D after switch", last_params and last_params.project_id == "project_D")
end

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, string.format("%d test(s) failed", fail_count))
print("✅ test_menu_project_id_staleness.lua passed")
