local M = {}
local timeline_state = require('ui.timeline.timeline_state')

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToStart"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing GoToStart command")
        end

        if dry_run then
            return true
        end

        timeline_state.set_playhead_value(0)
        print("✅ Moved playhead to start")
        return true
    end

    return {
        executor = command_executors["GoToStart"]
    }
end

return M
