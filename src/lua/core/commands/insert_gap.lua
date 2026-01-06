--- InsertGap: Minimal command for testing undo group functionality
-- Creates a gap (empty space) on a timeline at a given position

local M = {}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["InsertGap"] = function(command)
        -- Minimal implementation: just succeed and do nothing
        -- In a real implementation, this would insert a gap into the timeline
        return { success = true }
    end

    command_undoers["UndoInsertGap"] = function(command)
        -- Minimal implementation: just succeed and do nothing
        -- In a real implementation, this would remove the gap
        return { success = true }
    end

    return {
        executor = command_executors["InsertGap"],
        undoer = command_undoers["UndoInsertGap"]
    }
end

return M
