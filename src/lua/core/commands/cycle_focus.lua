--- CycleFocus command: Tab-key logic ported to the command system.
--- Ensures focus never escapes the current panel.
---
--- @module cycle_focus.lua
local M = {}

local log = require("core.logger").for_area("commands")

local SPEC = {
    name = "CycleFocus",
    description = "Cycle focus within the current panel",
    undoable = false,
    args = {
        direction = { required = false, default = "forward" },
        project_id = { required = false }
    },
}

function M.execute(_, args)
    local focus_manager = require("ui.focus_manager")
    local focused_panel = focus_manager.get_focused_panel()
    if not focused_panel then return false end

    local panel_widget = focus_manager.focus_panel_widget(focused_panel)
    if not panel_widget then return false end

    -- luacheck: globals qt_cycle_panel_focus
    if qt_cycle_panel_focus then
        local forward = (args.direction ~= "backward")
        log.detail("CycleFocus: %s in panel %s", args.direction, focused_panel)
        qt_cycle_panel_focus(panel_widget, forward)
        return true
    end

    return false
end

function M.register(executors, _, _, _)
    executors.CycleFocus = function(command)
        local args = command:get_all_parameters()
        local result = M.execute(nil, args)
        return result
    end

    return {
        CycleFocus = {
            executor = executors.CycleFocus,
            spec = SPEC,
        }
    }
end

return M
