#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua"

package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return "timeline" end,
    focus_panel = function() return true end,
    set_focused_panel = function() end,
}

local keyboard_shortcuts = require("core.keyboard_shortcuts")

local mock_state = {
    get_selected_clips = function()
        return {{id = "clip_123"}}
    end,
    get_sequence_id = function()
        return "sequence_test"
    end,
    set_selection = function() end,
}

local captured_command = nil
local mock_command_manager = {
    execute = function(command_or_name, params)
        if type(command_or_name) == "table" then
            captured_command = command_or_name
        else
            captured_command = {type = command_or_name, params = params}
        end
        return {success = true}
    end
}

keyboard_shortcuts.init(mock_state, mock_command_manager, nil, nil)

assert(keyboard_shortcuts.perform_delete_action({}), "Delete action should be handled")
assert(captured_command, "Delete action should dispatch a command")
assert(captured_command.type == "BatchCommand", "Command should be a BatchCommand")

local sequence_id = captured_command:get_parameter("sequence_id")
assert(sequence_id == "sequence_test", "BatchCommand must record active sequence_id")

local snapshot_targets = captured_command:get_parameter("__snapshot_sequence_ids")
assert(type(snapshot_targets) == "table" and snapshot_targets[1] == "sequence_test",
    "__snapshot_sequence_ids should include the active sequence")

print("✅ Keyboard shortcut delete wiring includes sequence metadata")
