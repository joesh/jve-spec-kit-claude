--- Undo meta-command: calls command_manager.undo().
--
-- Non-undoable. Clears redo toggle state before undoing.
--
-- @file undo.lua
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
        undo_redo_controller.handle_undo(command_manager)
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
