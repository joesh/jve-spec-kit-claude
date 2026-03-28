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
    return timeline_state.get_project_id and timeline_state.get_project_id() or nil
end

local function refresh_browser()
    local project_browser = require("ui.project_browser")
    if project_browser.refresh then
        project_browser.refresh()
    end
end

function M.register(command_executors, _, db, _)

    -- Sift: open the unified Find & Filter dialog
    command_executors["Sift"] = function(_)
        local view = get_active_view()
        local clips = view and view:get_clips() or {}
        local project_id = get_project_id()
        assert(project_id, "Sift: no project open")

        local find_dialog = require("ui.find_dialog")
        find_dialog.show({
            clips = clips,
            context = view and view.view_id or "project_browser",
            project_id = project_id,
        })

        return {success = true}
    end

    -- ExpandSift: scripting path with explicit params, or open dialog
    command_executors["ExpandSift"] = function(command)
        local args = command:get_all_parameters()
        if args.column and args.operator and args.value then
            local view = get_active_view()
            local clips = view and view:get_clips() or {}
            local project_id = get_project_id()
            assert(project_id, "ExpandSift: no project open")
            assert(sift_state.is_active(), "ExpandSift: no active sift")
            sift_commands.expand_sift(clips, {column = args.column, operator = args.operator, value = args.value}, project_id)
            refresh_browser()
            local eval = sift_state.evaluate(clips)
            return {success = true, visible_count = #eval.visible_ids}
        end
        return command_executors["Sift"](command)
    end

    -- NarrowSift: scripting path or dialog
    command_executors["NarrowSift"] = function(command)
        local args = command:get_all_parameters()
        if args.column and args.operator and args.value then
            local view = get_active_view()
            local clips = view and view:get_clips() or {}
            local project_id = get_project_id()
            assert(project_id, "NarrowSift: no project open")
            assert(sift_state.is_active(), "NarrowSift: no active sift")
            sift_commands.narrow_sift(clips, {column = args.column, operator = args.operator, value = args.value}, project_id)
            refresh_browser()
            local eval = sift_state.evaluate(clips)
            return {success = true, visible_count = #eval.visible_ids}
        end
        return command_executors["Sift"](command)
    end

    -- ClearSift
    command_executors["ClearSift"] = function(_)
        local project_id = get_project_id()
        if project_id then
            sift_commands.clear_sift(project_id)
        else
            sift_state.clear()
        end
        refresh_browser()
        return {success = true}
    end

    -- ShowTimelineIndex
    command_executors["ShowTimelineIndex"] = function(_)
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

    return {
        ["Sift"] = {executor = command_executors["Sift"], spec = SPEC_SIFT},
        ["ExpandSift"] = {executor = command_executors["ExpandSift"], spec = SPEC_SIFT},
        ["NarrowSift"] = {executor = command_executors["NarrowSift"], spec = SPEC_SIFT},
        ["ClearSift"] = {executor = command_executors["ClearSift"], spec = SPEC_SIFT},
        ["ShowTimelineIndex"] = {executor = command_executors["ShowTimelineIndex"], spec = SPEC_SIFT},
    }
end

return M
