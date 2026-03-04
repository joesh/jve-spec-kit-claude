--- SourceZoomFit command - resets source monitor mark bar to full extent
--
-- Responsibilities:
-- - Reset viewport to show entire clip (zoom-to-fit)
--
-- @file source_zoom_fit.lua
local M = {}

local SPEC = {
    undoable = false,
    no_project_context = true,
    args = {
        dry_run = { kind = "boolean" },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SourceZoomFit"] = function(command)
        local args = command:get_all_parameters()

        if args.dry_run then
            return true
        end

        local panel_manager
        do
            local ok, mod = pcall(require, 'ui.panel_manager')
            if ok then panel_manager = mod end
        end

        if not panel_manager then
            set_last_error("SourceZoomFit: panel_manager not available")
            return false
        end

        local ok, sm = pcall(panel_manager.get_sequence_monitor, "source_monitor")
        if not ok or not sm then
            set_last_error("SourceZoomFit: source_monitor not available")
            return false
        end

        sm:zoom_to_fit()
        return true
    end

    return {
        executor = command_executors["SourceZoomFit"],
        spec = SPEC,
    }
end

return M
