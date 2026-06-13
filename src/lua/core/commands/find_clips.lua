--- Find commands: Find, FindNext, FindPrevious, FindReplace, ClearFind
--
-- Find opens the find dialog. Navigation uses the active View's
-- navigate_to_clip() — no view-specific code here.
--
-- @file find_clips.lua

local find_state = require("core.find_state")
local Signals = require("core.signals")
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

--- Re-execute the current find query against the active view's clips.
-- Called when focus changes so matches update to the new view.
local function re_execute_for_view()
    local view = get_active_view()
    if not view then return end
    local clips = view:get_clips()
    -- Re-execute using the dialog's current text fields
    local find_dialog = require("ui.find_dialog")
    local query = find_dialog.get_current_query()
    if not query then
        log.event("re_execute_for_view: no query from dialog")
        return
    end
    log.event("re_execute_for_view: view=%s clips=%d query=%s %s %s",
        view.view_id, #clips, query.column, query.operator, query.value)
    find_state.execute(clips, query)
    log.event("re_execute_for_view: %d matches", find_state.get_match_count())
end

-- ============================================================================
-- Command executors
-- ============================================================================

function M.register(command_executors, _, _, _)

    -- Re-execute find when timeline content changes (clips renamed, relinked, etc.)
    Signals.connect("sequence_content_changed", function()
        if not find_state.is_active() then return end
        local find_dialog = require("ui.find_dialog")
        if not find_dialog.is_visible() then return end
        log.event("sequence_content_changed: re-executing find with fresh clips")
        re_execute_for_view()
    end)

    -- Register focus change listener to re-execute find for new view
    local focus_manager = require("ui.focus_manager")
    focus_manager.on_focus_change(function(_, new_id)
        if find_state.is_active() and new_id then
            local new_view = focus_manager.get_view(new_id)
            if new_view then
                log.event("focus changed to %s, re-executing find", new_id)
                -- Update dialog's clip list
                local find_dialog = require("ui.find_dialog")
                find_dialog.update_clips(new_view:get_clips())
                re_execute_for_view()
            end
        end
    end)

    command_executors["Find"] = function(_)
        local view = get_active_view()
        if not view then
            log.warn("Find: no active view")
            return {success = false, error_message = "No active view"}
        end
        log.event("Find: view %s", view.view_id)

        if view.view_id == "project_browser" then
            -- Browser: show embedded find bar, focus + select text
            local pb = require("ui.project_browser")
            pb.show_find_bar()
            return {success = true}
        end

        -- Timeline: floating dialog (no inline find bar for the timeline panel yet)
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
            on_select_all = function(match_ids)
                log.event("Find on_select_all: %d clips", #match_ids)
                local target = get_active_view() or view
                target:select_clips(match_ids)
            end,
        })

        return {success = true}
    end

    local function get_playhead_frame()
        local ok, ts = pcall(require, "ui.timeline.timeline_state")
        if not ok or type(ts) ~= "table" then return nil end
        return ts.get_playhead_position and ts.get_playhead_position()
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
        local frame = get_playhead_frame()
        if frame then
            find_state.next_from(frame)
        else
            find_state.next()
        end
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
        local frame = get_playhead_frame()
        if frame then
            find_state.prev_from(frame)
        else
            find_state.previous()
        end
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
