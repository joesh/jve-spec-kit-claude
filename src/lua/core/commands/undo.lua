--- Undo meta-command: dispatches the pure model-level undo.
--
-- Non-undoable. The interactive entry point (Cmd+Z keyboard, Edit menu)
-- dispatches "Undo" via execute_interactive, which opens a single "ui"
-- event. This executor then calls the pure command_manager.undo() — the
-- Pass 2 viewport policy fires once at the outer execute_interactive
-- wrapper, seeing the undone command's mutations via forwarding.
--
-- @file undo.lua
local M = {}

local SPEC = {
    undoable = false,
    -- Viewport policy is owned by the undo ceremony inside
    -- command_manager.undo(), which surfaces the change region of the
    -- undone command. execute_interactive must NOT re-fire its generic
    -- execute policy on top, or it would overwrite the region scroll
    -- with a surface-playhead call.
    skip_execute_viewport_policy = true,
    args = {
        project_id = {},
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local command_manager = require("core.command_manager")
        if not command_manager.can_undo() then
            print("Nothing to undo")
            return true
        end
        local result = command_manager.undo()
        if result.success then
            print("Undo complete")
        elseif result.error_message then
            print("ERROR: Undo failed - " .. result.error_message)
        else
            print("ERROR: Undo failed - event log may be corrupted")
        end
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
