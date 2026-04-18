--- Redo meta-command: dispatches the pure model-level redo.
--
-- Non-undoable. The interactive entry point (Cmd+Shift+Z keyboard, Edit
-- menu) dispatches "Redo" via execute_interactive, which opens a single
-- "ui" event. This executor then calls the pure command_manager.redo() —
-- the Pass 2 viewport policy fires once at the outer execute_interactive
-- wrapper, seeing the redone command's mutations via forwarding.
--
-- @file redo.lua
local M = {}
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    -- Viewport policy is owned by the redo ceremony inside
    -- command_manager.redo() (same reason as Undo — the outer
    -- execute_interactive must not re-fire generic execute policy and
    -- overwrite the region scroll).
    skip_execute_viewport_policy = true,
    args = {
        project_id = {},
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local command_manager = require("core.command_manager")
        if not command_manager.can_redo() then
            log.event("Redo: nothing to redo")
            return true
        end
        local result = command_manager.redo()
        if result.success then
            log.event("Redo: complete")
        elseif result.error_message then
            log.event("Redo: nothing to redo (%s)", result.error_message)
        else
            log.event("Redo: nothing to redo")
        end
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
