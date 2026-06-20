--- Find commands: Find, FindNext, FindPrevious, SelectAllMatches,
--- FindReplaceCurrent, FindReplaceAll, FindReplace, ClearFind
--
-- Find opens the find dialog (pure view). The dialog dispatches every
-- action as a command; all find execution and state live here and in
-- find_state. Navigation uses the active View's navigate_to_clip().
--
-- @file find_clips.lua

local find_state = require("core.find_state")
local Signals = require("core.signals")
local log = require("core.logger").for_area("ui.find")

local M = {}

-- The find dialog is a pure view: it dispatches every action with the user's
-- query packet. These keys are optional at the schema layer (Find/FindNext open
-- the dialog when absent); each executor asserts the subset it actually needs
-- (e.g. SelectAllMatches / FindReplace* require column+operator+value).
local SPEC_FIND = {
    undoable = false,
    args = {
        column        = { kind = "string" },
        operator      = { kind = "string" },
        value         = { kind = "string" },
        replace_value = { kind = "string" },
    },
}

-- ============================================================================
-- Helpers
-- ============================================================================

local function get_active_view()
    local focus_manager = require("ui.focus_manager")
    return focus_manager.get_active_view()
end

local function get_timeline_state()
    local ok, ts = pcall(require, "ui.timeline.timeline_state")
    if not ok or type(ts) ~= "table" then return nil end
    return ts
end

local function get_project_id()
    local ts = get_timeline_state()
    return ts and ts.get_project_id and ts.get_project_id()
end

local function get_playhead_frame()
    local ts = get_timeline_state()
    return ts and ts.get_playhead_position and ts.get_playhead_position()
end

local function make_query(args)
    return {column = args.column, operator = args.operator, value = args.value}
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

local function update_find_status(text)
    local fd = require("ui.find_dialog")
    if fd.is_visible() then fd.update_status(text) end
end

local function execute_find(query)
    local view = get_active_view()
    assert(view, "execute_find: no active view")
    find_state.execute(view:get_clips(), query)
    return find_state.get_match_count()
end

local function query_matches_active(column, operator, value)
    if not find_state.is_active() then return false end
    local current = find_state.get_current_query()
    if not current or #current == 0 then return false end
    local q = current[1]
    return q.column == column and q.operator == operator and q.value == value
end

--- Re-execute find when args carry a different query than the active session.
-- Returns the new match count when re-executed; nil when query unchanged (caller should advance).
local function re_execute_if_changed(args)
    if not (args.column and args.operator and args.value) then return nil end
    if query_matches_active(args.column, args.operator, args.value) then return nil end
    return execute_find(make_query(args))
end

local function complete_navigation()
    navigate_to_match()
    local idx = find_state.get_current_index()
    local total = find_state.get_match_count()
    update_find_status(string.format("Match %d of %d", idx, total))
    return {success = true, current_match = find_state.get_current_match()}
end

--- Re-execute find against the active view using the dialog's current query.
-- Called when content or focus changes while find is active.
local function re_execute_for_view()
    local view = get_active_view()
    if not view then return end
    local find_dialog = require("ui.find_dialog")
    local query = find_dialog.get_current_query()
    if not query then
        log.event("re_execute_for_view: no query from dialog")
        return
    end
    local clips = view:get_clips()
    log.event("re_execute_for_view: view=%s clips=%d query=%s %s %s",
        view.view_id, #clips, query.column, query.operator, query.value)
    find_state.execute(clips, query)
    local count = find_state.get_match_count()
    log.event("re_execute_for_view: %d matches", count)
    update_find_status(string.format("%d match%s", count, count == 1 and "" or "es"))
end

-- ============================================================================
-- Command executor implementations
-- ============================================================================

local function cmd_find(command)
    local args = command:get_all_parameters()
    local view = get_active_view()
    if not view then
        log.warn("Find: no active view")
        return {success = false, error_message = "No active view"}
    end
    log.event("Find: view %s", view.view_id)

    if view.view_id == "project_browser" then
        local pb = require("ui.project_browser")
        pb.show_find_bar()
        return {success = true}
    end

    local find_dialog = require("ui.find_dialog")

    if not (args.column and args.operator and args.value) then
        find_dialog.show()
        return {success = true}
    end

    local count = execute_find(make_query(args))
    if count == 0 then
        update_find_status("No matches")
    else
        update_find_status(string.format("%d match%s", count, count == 1 and "" or "es"))
        navigate_to_match()
    end
    return {success = true, match_count = count}
end

local function cmd_find_next(command)
    local args = command:get_all_parameters()
    log.event("FindNext: active=%s count=%d idx=%d",
        tostring(find_state.is_active()),
        find_state.get_match_count(),
        find_state.get_current_index())

    if not find_state.is_active() then
        log.event("FindNext: no active session, opening Find dialog")
        return cmd_find(command)
    end

    local fresh_count = re_execute_if_changed(args)
    if fresh_count == 0 then
        update_find_status("No matches")
        return {success = true, match_count = 0}
    end
    if fresh_count == nil then
        local frame = get_playhead_frame()
        if frame then find_state.next_from(frame) else find_state.next() end
    end

    log.event("FindNext: idx=%d match=%s",
        find_state.get_current_index(), tostring(find_state.get_current_match()))
    return complete_navigation()
end

local function cmd_find_previous(command)
    local args = command:get_all_parameters()
    if not find_state.is_active() then
        log.event("FindPrevious: no active session, opening Find dialog")
        return cmd_find(command)
    end

    local fresh_count = re_execute_if_changed(args)
    if fresh_count == 0 then
        update_find_status("No matches")
        return {success = true, match_count = 0}
    end
    if fresh_count == nil then
        local frame = get_playhead_frame()
        if frame then find_state.prev_from(frame) else find_state.previous() end
    elseif fresh_count > 0 then
        -- Fresh result set: land on last match when stepping backward
        for _ = 1, fresh_count - 1 do find_state.next() end
    end

    return complete_navigation()
end

local function cmd_select_all_matches(command)
    local args = command:get_all_parameters()
    assert(args.column and args.operator and args.value,
        "SelectAllMatches: column, operator, value required")

    local view = get_active_view()
    assert(view, "SelectAllMatches: no active view")

    local fresh_count = re_execute_if_changed(args)
    if fresh_count == 0 then
        view:select_clips({})
        update_find_status("No matches")
        return {success = true, selected_count = 0}
    end

    local match_ids = find_state.get_matches()
    view:select_clips(match_ids)
    local count = #match_ids
    update_find_status(string.format("Selected %d clip%s", count, count == 1 and "" or "s"))
    return {success = true, selected_count = count}
end

local function cmd_find_replace_current(command)
    local args = command:get_all_parameters()
    assert(args.column and args.operator and args.value and args.replace_value,
        "FindReplaceCurrent: column, operator, value, replace_value required")

    local fresh_count = re_execute_if_changed(args)
    if fresh_count == 0 then
        update_find_status("No matches")
        return {success = true, replaced_count = 0}
    end

    local match_id = find_state.get_current_match()
    if not match_id then
        update_find_status("No current match")
        return {success = true, replaced_count = 0}
    end

    local project_id = get_project_id()
    assert(project_id, "FindReplaceCurrent: no project open")

    local cm = require("core.command_manager")
    cm.execute_interactive("ReplaceClipProperty", {
        project_id    = project_id,
        clip_id       = match_id,
        column        = args.column,
        find_value    = args.value,
        replace_value = args.replace_value,
    })

    find_state.next()
    navigate_to_match()
    local idx = find_state.get_current_index()
    local total = find_state.get_match_count()
    update_find_status(string.format("Replaced — Match %d of %d", idx, total))
    return {success = true, replaced_count = 1}
end

local function cmd_find_replace_all(command)
    local args = command:get_all_parameters()
    assert(args.column and args.operator and args.value and args.replace_value,
        "FindReplaceAll: column, operator, value, replace_value required")

    local fresh_count = re_execute_if_changed(args)
    if fresh_count == 0 then
        update_find_status("No matches")
        return {success = true, replaced_count = 0}
    end

    local match_ids = find_state.get_matches()
    local count = #match_ids
    if count == 0 then
        update_find_status("No matches")
        return {success = true, replaced_count = 0}
    end

    local project_id = get_project_id()
    assert(project_id, "FindReplaceAll: no project open")

    local cm = require("core.command_manager")
    cm.execute_interactive("ReplaceAllClipProperties", {
        project_id    = project_id,
        clip_ids      = match_ids,
        column        = args.column,
        find_value    = args.value,
        replace_value = args.replace_value,
    })

    update_find_status(string.format("Replaced %d clip%s", count, count == 1 and "" or "s"))
    return {success = true, replaced_count = count}
end

local function cmd_clear_find(_)
    find_state.clear()
    update_find_status("")
    return {success = true}
end

-- ============================================================================
-- Register
-- ============================================================================

function M.register(command_executors, _, _, _)

    Signals.connect("sequence_content_changed", function()
        if not find_state.is_active() then return end
        local find_dialog = require("ui.find_dialog")
        if not find_dialog.is_visible() then return end
        log.event("sequence_content_changed: re-executing find with fresh clips")
        re_execute_for_view()
    end)

    local focus_manager = require("ui.focus_manager")
    focus_manager.on_focus_change(function(_, new_id)
        if find_state.is_active() and new_id then
            local new_view = focus_manager.get_view(new_id)
            if new_view then
                log.event("focus changed to %s, re-executing find", new_id)
                re_execute_for_view()
            end
        end
    end)

    command_executors["Find"]               = cmd_find
    command_executors["FindNext"]           = cmd_find_next
    command_executors["FindPrevious"]       = cmd_find_previous
    command_executors["FindReplace"]        = cmd_find
    command_executors["SelectAllMatches"]   = cmd_select_all_matches
    command_executors["FindReplaceCurrent"] = cmd_find_replace_current
    command_executors["FindReplaceAll"]     = cmd_find_replace_all
    command_executors["ClearFind"]          = cmd_clear_find

    return {
        ["Find"]               = {executor = cmd_find,                spec = SPEC_FIND},
        ["FindNext"]           = {executor = cmd_find_next,           spec = SPEC_FIND},
        ["FindPrevious"]       = {executor = cmd_find_previous,       spec = SPEC_FIND},
        ["FindReplace"]        = {executor = cmd_find,                spec = SPEC_FIND},
        ["SelectAllMatches"]   = {executor = cmd_select_all_matches,   spec = SPEC_FIND},
        ["FindReplaceCurrent"] = {executor = cmd_find_replace_current, spec = SPEC_FIND},
        ["FindReplaceAll"]     = {executor = cmd_find_replace_all,     spec = SPEC_FIND},
        ["ClearFind"]          = {executor = cmd_clear_find,           spec = SPEC_FIND},
    }
end

return M
