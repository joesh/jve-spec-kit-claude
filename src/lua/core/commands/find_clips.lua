--- Find commands: Find, FindNext, FindPrevious, FindReplace, ClearFind
--
-- Find opens the find dialog. Navigation uses the active View's
-- navigate_to_clip() — no view-specific code here.
--
-- @file find_clips.lua

local find_state = require("core.find_state")
local log = require("core.logger").for_area("ui.find")

local M = {}

local SPEC_FIND = { undoable = false, args = {} }
local SPEC_FIND_NEXT = { undoable = false, args = {} }

-- ============================================================================
-- Helpers
-- ============================================================================

local function get_active_view()
    local focus_manager = require("ui.focus_manager")
    return focus_manager.get_active_view()
end

local function navigate_to_match()
    local match_id = find_state.get_current_match()
    log.event("navigate_to_match: match_id=%s", tostring(match_id))
    if not match_id then return end
    local view = get_active_view()
    log.event("navigate_to_match: view=%s view_id=%s", tostring(view), view and view.view_id or "nil")
    if view then
        view:navigate_to_clip(match_id)
    else
        log.warn("navigate_to_match: no active view")
    end
end

-- ============================================================================
-- Command executors
-- ============================================================================

function M.register(command_executors, _, _, _)

    command_executors["Find"] = function(_)
        local view = get_active_view()
        if not view then
            log.warn("Find: no active view")
            return {success = false, error_message = "No active view"}
        end

        local clips = view:get_clips()
        if #clips == 0 then
            log.warn("Find: no clips in current view")
            return {success = true, match_count = 0}
        end

        local timeline_state = require("ui.timeline.timeline_state")
        local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or nil

        local find_dialog = require("ui.find_dialog")
        find_dialog.show({
            clips = clips,
            context = view.view_id,
            project_id = project_id,
            on_find = function()
                navigate_to_match()
            end,
            on_navigate = function()
                navigate_to_match()
            end,
        })

        return {success = true}
    end

    command_executors["FindNext"] = function(_)
        log.event("FindNext: active=%s count=%d idx=%d",
            tostring(find_state.is_active()),
            find_state.get_match_count(),
            find_state.get_current_index())
        if not find_state.is_active() then
            -- No active find — open the dialog so user can enter search text
            log.event("FindNext: no active session, opening Find dialog")
            return command_executors["Find"](_)
        end
        find_state.next()
        local match = find_state.get_current_match()
        log.event("FindNext: after next idx=%d match=%s",
            find_state.get_current_index(), tostring(match))
        navigate_to_match()
        return {success = true, current_match = match}
    end

    command_executors["FindPrevious"] = function(_)
        if not find_state.is_active() then
            log.event("FindPrevious: no active session, opening Find dialog")
            return command_executors["Find"](_)
        end
        find_state.previous()
        navigate_to_match()
        return {success = true, current_match = find_state.get_current_match()}
    end

    command_executors["FindReplace"] = function(command)
        return command_executors["Find"](command)
    end

    command_executors["ClearFind"] = function(_)
        find_state.clear()
        return {success = true}
    end

    return {
        ["Find"] = {executor = command_executors["Find"], spec = SPEC_FIND},
        ["FindNext"] = {executor = command_executors["FindNext"], spec = SPEC_FIND_NEXT},
        ["FindPrevious"] = {executor = command_executors["FindPrevious"], spec = SPEC_FIND_NEXT},
        ["FindReplace"] = {executor = command_executors["FindReplace"], spec = SPEC_FIND},
        ["ClearFind"] = {executor = command_executors["ClearFind"], spec = SPEC_FIND_NEXT},
    }
end

return M
