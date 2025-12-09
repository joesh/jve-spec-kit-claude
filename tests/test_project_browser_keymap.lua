#!/usr/bin/env luajit

package.path = package.path
    .. ";./tests/?.lua"
    .. ";./src/lua/?.lua"
    .. ";./src/lua/ui/?.lua"
    .. ";./src/lua/ui/project_browser/?.lua"

require("test_env")

local keymap = require("ui.project_browser.keymap")

local KEY_RETURN = 16777220

local function run_toggle_with_numeric_event()
    local expanded = false
    local focused = false
    local last_set_state = nil

    local ctx = {
        get_selected_item = function()
            return { type = "bin", tree_id = "bin1" }
        end,
        resolve_tree_id = function(item)
            return item and item.tree_id or nil
        end,
        tree_widget = function()
            return {}
        end,
        focus_tree = function()
            focused = true
        end,
        controls = {
            IS_TREE_ITEM_EXPANDED = function(_, _)
                return expanded
            end,
            SET_TREE_ITEM_EXPANDED = function(_, _, state)
                expanded = state
                last_set_state = state
            end
        }
    }

    local handled = keymap.handle(KEY_RETURN, ctx)
    assert(handled == true, "numeric keycode should toggle bin and return true")
    assert(expanded == true, "bin should be expanded after toggle")
    assert(last_set_state == true, "SET_TREE_ITEM_EXPANDED should be called with true")
    assert(focused == true, "focus_tree should be invoked when toggling")
end

local function run_ignores_unhandled_event()
    local ctx = { get_selected_item = function() return nil end }
    local handled = keymap.handle(123, ctx)
    assert(handled == false, "non-toggle key should be ignored")
end

run_toggle_with_numeric_event()
run_ignores_unhandled_event()

print("✅ project_browser keymap numeric event test passed")
