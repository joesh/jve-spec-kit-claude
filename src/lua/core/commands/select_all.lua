local M = {}
local timeline_state = require('ui.timeline.timeline_state')

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SelectAll"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing SelectAll command")
        end

        local focus_manager_ok, focus_manager = pcall(require, "ui.focus_manager")
        local focused_panel = nil
        if focus_manager_ok and focus_manager and focus_manager.get_focused_panel then
            focused_panel = focus_manager.get_focused_panel()
        end

        if focused_panel == "project_browser" then
            if dry_run then
                return true
            end
            local ok, result = pcall(function()
                local project_browser = require("ui.project_browser")
                if project_browser and project_browser.select_all_items then
                    return project_browser.select_all_items()
                end
                return false, "Project browser select_all not available"
            end)
            if ok and result then
                print("✅ Selected all items in Project Browser")
                return true
            end
            print(string.format("SelectAll (Project Browser) failed: %s", result or "unknown error"))
            return false
        end

        if dry_run then
            return true, {total_clips = #(timeline_state.get_clips() or {})}
        end

        local all_clips = timeline_state.get_clips() or {}
        if #all_clips == 0 then
            timeline_state.set_selection({})
            timeline_state.clear_edge_selection()
            print("SelectAll: no clips available to select")
            return true
        end

        timeline_state.set_selection(all_clips)
        timeline_state.clear_edge_selection()
        print(string.format("✅ Selected all %d clip(s)", #all_clips))
        return true
    end

    return {
        executor = command_executors["SelectAll"]
    }
end

return M
