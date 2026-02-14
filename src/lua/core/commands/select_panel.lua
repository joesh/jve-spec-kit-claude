--- SelectPanel command: focus a named panel.
--
-- Non-undoable. Positional arg specifies which panel: timeline, inspector, project_browser.
--
-- @file select_panel.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        _positional = {},  -- panel name as first positional arg
        project_id = {},
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local args = command:get_all_parameters()
        local positional = args._positional or {}
        local panel_id = positional[1]
        assert(panel_id and panel_id ~= "", "SelectPanel: panel name required (e.g. timeline, inspector, project_browser)")

        local focus_manager = require("ui.focus_manager")
        if focus_manager.focus_panel then
            focus_manager.focus_panel(panel_id)
        elseif focus_manager.set_focused_panel then
            focus_manager.set_focused_panel(panel_id)
        end
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
