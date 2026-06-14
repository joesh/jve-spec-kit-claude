--- Sift commands: Sift, ExpandSift, NarrowSift, ClearSift, ShowTimelineIndex
--
-- Sift opens the unified find dialog (which includes sift buttons).
-- Expand/Narrow/Clear operate on existing sift state via scripting.
-- All use the active View's get_clips() for clip data.
--
-- @file sift.lua

local sift_commands = require("core.sift_commands")
local sift_state = require("core.sift_state")
local log = require("core.logger").for_area("ui")

local M = {}

local SPEC_SIFT = { undoable = false, args = {} }

local function get_active_view()
    local focus_manager = require("ui.focus_manager")
    return focus_manager.get_active_view()
end

local function get_project_id()
    local timeline_state = require("ui.timeline.timeline_state")
    return timeline_state.get_project_id and timeline_state.get_project_id()
end

local function refresh_browser()
    local project_browser = require("ui.project_browser")
    if project_browser.refresh then
        project_browser.refresh()
    end
end

--- Execute a sift operation (expand or narrow) against the active view's clips.
local function execute_sift_op(sift_fn, args, command_name)
    local view = get_active_view()
    assert(view, command_name .. ": no active view")
    local clips = view:get_clips()
    local project_id = get_project_id()
    assert(project_id, command_name .. ": no project open")
    assert(sift_state.is_active(), command_name .. ": no active sift")
    sift_fn(clips, {column = args.column, operator = args.operator, value = args.value}, project_id)
    refresh_browser()
    local eval = sift_state.evaluate(clips)
    return {success = true, visible_count = #eval.visible_ids}
end

local function cmd_sift(_)
    local find_dialog = require("ui.find_dialog")
    find_dialog.show()
    return {success = true}
end

local function cmd_expand_sift(command)
    local args = command:get_all_parameters()
    if args.column and args.operator and args.value then
        return execute_sift_op(sift_commands.expand_sift, args, "ExpandSift")
    end
    return cmd_sift(command)
end

local function cmd_narrow_sift(command)
    local args = command:get_all_parameters()
    if args.column and args.operator and args.value then
        return execute_sift_op(sift_commands.narrow_sift, args, "NarrowSift")
    end
    return cmd_sift(command)
end

local function cmd_clear_sift(_)
    local project_id = get_project_id()
    if project_id then
        sift_commands.clear_sift(project_id)
    else
        sift_state.clear()
    end
    refresh_browser()
    return {success = true}
end

local function cmd_show_timeline_index(_)
    local focus_manager = require("ui.focus_manager")
    local view = focus_manager.get_view("timeline")
    if not view then
        log.warn("ShowTimelineIndex: no timeline view")
        return {success = false}
    end
    local clips = view:get_clips()
    local timeline_index = require("ui.timeline_index")
    timeline_index.show({
        clips = clips,
        on_navigate = function(clip_id)
            view:navigate_to_clip(clip_id)
        end,
    })
    return {success = true}
end

function M.register(command_executors, _, _, _)
    command_executors["Sift"]              = cmd_sift
    command_executors["ExpandSift"]        = cmd_expand_sift
    command_executors["NarrowSift"]        = cmd_narrow_sift
    command_executors["ClearSift"]         = cmd_clear_sift
    command_executors["ShowTimelineIndex"] = cmd_show_timeline_index

    return {
        ["Sift"]              = {executor = cmd_sift,                spec = SPEC_SIFT},
        ["ExpandSift"]        = {executor = cmd_expand_sift,         spec = SPEC_SIFT},
        ["NarrowSift"]        = {executor = cmd_narrow_sift,         spec = SPEC_SIFT},
        ["ClearSift"]         = {executor = cmd_clear_sift,          spec = SPEC_SIFT},
        ["ShowTimelineIndex"] = {executor = cmd_show_timeline_index, spec = SPEC_SIFT},
    }
end

return M
