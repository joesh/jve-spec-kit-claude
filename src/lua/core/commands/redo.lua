--- Redo meta-command: calls command_manager.redo() with toggle state machine.
--
-- Non-undoable. Uses undo_redo_controller for redo toggle behavior.
--
-- @file redo.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        project_id = {},
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local command_manager = require("core.command_manager")
        local undo_redo_controller = require("core.undo_redo_controller")
        undo_redo_controller.handle_redo_toggle(command_manager)
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
