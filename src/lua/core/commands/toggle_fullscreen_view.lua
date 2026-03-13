--- ToggleFullscreenView: toggle output-only fullscreen video surface.
--
-- Non-undoable. Enters fullscreen for the currently focused viewer,
-- or exits if already active.
--
-- @file toggle_fullscreen_view.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {},
}

function M.register(executors, undoers, _db)
    local function executor(_command)
        local fullscreen_viewer = require("ui.fullscreen_viewer")
        local focus_manager = require("ui.focus_manager")

        if fullscreen_viewer.is_active() then
            fullscreen_viewer.exit()
            return true
        end

        -- Determine which viewer to fullscreen based on focus
        local focused = focus_manager.get_focused_panel()
        local view_id
        if focused == "source_monitor" then
            view_id = "source_monitor"
        else
            view_id = "timeline_monitor"
        end

        fullscreen_viewer.enter(view_id)
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
