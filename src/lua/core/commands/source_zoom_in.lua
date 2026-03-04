--- SourceZoomIn command - zooms in the source monitor mark bar
--
-- Responsibilities:
-- - Reduce viewport duration by 20% (multiply by 0.8)
-- - Centered on playhead, enforces 30-frame minimum
--
-- @file source_zoom_in.lua
local M = {}

local SPEC = {
    undoable = false,
    no_project_context = true,
    args = {
        dry_run = { kind = "boolean" },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SourceZoomIn"] = function(command)
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
            set_last_error("SourceZoomIn: panel_manager not available")
            return false
        end

        local ok, sm = pcall(panel_manager.get_sequence_monitor, "source_monitor")
        if not ok or not sm then
            set_last_error("SourceZoomIn: source_monitor not available")
            return false
        end

        sm:zoom_by(0.8)
        return true
    end

    return {
        executor = command_executors["SourceZoomIn"],
        spec = SPEC,
    }
end

return M
