-- ToggleMaximizePanel command
local M = {}

function M.register(executors, undoers, db)
    
    executors["ToggleMaximizePanel"] = function(command)
        local panel_manager = require("ui.panel_manager")
        local panel_id = command:get_parameter("panel_id")
        local ok, err = panel_manager.toggle_maximize(panel_id)
        if not ok and err then
            print(string.format("WARNING: ToggleMaximizePanel: %s", err))
        end
        return true
    end

    -- No undo needed for UI state changes that are non-recording
    return {executor = executors["ToggleMaximizePanel"]}
end

return M
