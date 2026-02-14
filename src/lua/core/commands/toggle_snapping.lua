--- ToggleSnapping command: toggle magnetic snapping on/off.
--
-- Non-undoable. Toggles the baseline snapping preference (not drag inversion).
--
-- @file toggle_snapping.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        project_id = {},
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local snapping_state = require("ui.timeline.state.snapping_state")
        snapping_state.toggle_baseline()
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
