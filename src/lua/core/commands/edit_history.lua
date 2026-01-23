--- EditHistory command - opens the edit history window
--
-- Responsibilities:
-- - Show the edit history window for navigating undo/redo stack
--
-- @file edit_history.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = {},  -- auto-passed by menu system
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local edit_history_window = require("ui.edit_history_window")
        local command_manager = require("core.command_manager")

        edit_history_window.show(command_manager, nil)
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
