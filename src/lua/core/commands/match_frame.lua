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
-- Size: ~52 LOC
-- Volatility: unknown
--
-- @file match_frame.lua
local M = {}
local timeline_state = require('ui.timeline.timeline_state')
local project_browser = require('ui.project_browser')


local SPEC = {
    args = {
        project_id = { required = true },
        skip_activate = {},
        skip_focus = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["MatchFrame"] = function(command)
        local args = command:get_all_parameters()
        local selected = timeline_state.get_selected_clips and timeline_state.get_selected_clips() or {}
        if not selected or #selected == 0 then
            set_last_error("MatchFrame: No clips selected")
            return false
        end

        local function extract_parent_id(entry)
            if type(entry) ~= "table" then
                return nil
            end
            if entry.parent_clip_id and entry.parent_clip_id ~= "" then
                return entry.parent_clip_id
            end
            if entry.parent_id and entry.parent_id ~= "" then
                return entry.parent_id
            end
            return nil
        end

        local target_master_id = nil
        for _, clip in ipairs(selected) do
            target_master_id = extract_parent_id(clip)
            if target_master_id then
                break
            end
        end

        if not target_master_id then
            set_last_error("MatchFrame: Selected clip is not linked to a master clip")
            return false
        end

        local ok, err = pcall(project_browser.focus_master_clip, target_master_id, {
            skip_focus = args.skip_focus == true,
            skip_activate = args.skip_activate == true
        })
        if not ok then
            set_last_error("MatchFrame: " .. tostring(err))
            return false
        end

        if err == false then
            set_last_error("MatchFrame: Failed to focus master clip")
            return false
        end

        return true
    end

    return {
        executor = command_executors["MatchFrame"],
        spec = SPEC,
    }
end

return M