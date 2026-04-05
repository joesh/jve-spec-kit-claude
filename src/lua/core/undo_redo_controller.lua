--- Undo/redo dispatch.
--
-- Straightforward: Cmd+Z undoes, Cmd+Shift+Z redoes.
-- At the end of history, redo does nothing.
--
-- @file undo_redo_controller.lua
local M = {}

--- Handle undo (Cmd+Z).
function M.handle_undo(command_manager)
    assert(command_manager, "undo_redo_controller.handle_undo: command_manager required")

    if command_manager.can_undo and not command_manager.can_undo() then
        return { success = false, error_message = "nothing to undo" }
    end
    local result = command_manager.undo()
    assert(type(result) == "table", "undo_redo_controller.handle_undo: undo() must return table")
    if result.success then
        print("Undo complete")
    else
        if result.error_message then
            print("ERROR: Undo failed - " .. result.error_message)
        else
            print("ERROR: Undo failed - event log may be corrupted")
        end
    end
    return result
end

--- Handle redo (Cmd+Shift+Z).
function M.handle_redo_toggle(command_manager)
    assert(command_manager, "undo_redo_controller.handle_redo_toggle: command_manager required")

    if command_manager.can_redo and not command_manager.can_redo() then
        return { success = false, error_message = "nothing to redo" }
    end
    local result = command_manager.redo()
    assert(type(result) == "table", "undo_redo_controller.handle_redo_toggle: redo() must return table")
    if result.success then
        print("Redo complete")
    else
        if result.error_message then
            print("Nothing to redo (" .. result.error_message .. ")")
        else
            print("Nothing to redo")
        end
    end
    return result
end

-- Kept for API compat — now a no-op
function M.clear_toggle() end

return M
