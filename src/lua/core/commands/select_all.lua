--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~51 LOC
-- Volatility: unknown
--
-- @file select_all.lua
local M = {}
local timeline_state = require('ui.timeline.timeline_state')


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
            print("Executing SelectAll command")
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
                print("✅ Selected all items in Project Browser")
                return true
            end
            print(string.format("SelectAll (Project Browser) failed: %s", result or "unknown error"))
            return false
        end

        if args.dry_run then
            return true, {total_clips = #(timeline_state.get_clips() or {})}
        end

        -- Filter out gap clips — they're derived state, not selectable for clip operations
        local media_clips = {}
        for _, clip in ipairs(timeline_state.get_clips() or {}) do
            if clip.clip_kind ~= "gap" then
                media_clips[#media_clips + 1] = clip
            end
        end
        if #media_clips == 0 then
            timeline_state.set_selection({})
            timeline_state.clear_edge_selection()
            print("SelectAll: no clips available to select")
            return true
        end

        timeline_state.set_selection(media_clips)
        timeline_state.clear_edge_selection()
        print(string.format("✅ Selected all %d clip(s)", #media_clips))
        return true
    end

    return {
        executor = command_executors["SelectAll"],
        spec = SPEC,
    }
end

return M
