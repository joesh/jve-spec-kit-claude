local M = {}
local timeline_state = require('ui.timeline.timeline_state')
local log = require('core.logger').for_area('commands')


local SPEC = {
    undoable = false,
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SelectAll"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            log.event("Executing SelectAll")
        end

        local focus_manager_ok, focus_manager = pcall(require, "ui.focus_manager")
        local focused_panel = nil
        if focus_manager_ok and focus_manager and focus_manager.get_focused_panel then
            focused_panel = focus_manager.get_focused_panel()
        end

        if focused_panel == "project_browser" then
            if args.dry_run then
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
                log.event("SelectAll: project browser")
                return true
            end
            log.warn("SelectAll (project browser) failed: %s",
                tostring(result or "unknown error"))
            return false
        end

        if args.dry_run then
            return true, {total_clips = #(timeline_state.get_clips())}
        end

        -- Filter out gap clips — they're derived state, not selectable for clip operations
        local media_clips = {}
        for _, clip in ipairs(timeline_state.get_clips()) do
            if not clip.is_gap then
                media_clips[#media_clips + 1] = clip
            end
        end
        if #media_clips == 0 then
            timeline_state.set_selection({})
            timeline_state.clear_edge_selection()
            log.event("SelectAll: no clips available to select")
            return true
        end

        timeline_state.set_selection(media_clips)
        timeline_state.clear_edge_selection()
        log.event("Selected all %d clip(s)", #media_clips)
        return true
    end

    return {
        executor = command_executors["SelectAll"],
        spec = SPEC,
    }
end

return M
