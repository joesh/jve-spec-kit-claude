--- ToggleSnapping command: context-aware magnetic snapping toggle.
--
-- Non-undoable. During drag → invert drag snapping. Otherwise → toggle baseline.
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
        -- During active drag, N inverts snapping for this drag only.
        -- Outside drag, N toggles the baseline preference.
        local ok, ks = pcall(require, "core.keyboard_shortcuts")
        if ok and ks and ks.is_dragging and ks.is_dragging() then
            snapping_state.invert_drag()
        else
            snapping_state.toggle_baseline()
        end
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
