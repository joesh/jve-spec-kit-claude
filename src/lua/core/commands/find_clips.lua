--- Find commands: Find, FindNext, FindPrevious, FindReplace, ClearFind
--
-- Find opens the find dialog, gathers clips from browser/timeline context.
-- FindNext/FindPrevious cycle through matches.
-- FindReplace opens the find & replace dialog.
--
-- @file find_clips.lua

local find_state = require("core.find_state")
local log = require("core.logger").for_area("ui")

local M = {}

local SPEC_FIND = {
    undoable = false,
    args = {},
}

local SPEC_FIND_NEXT = {
    undoable = false,
    args = {},
}

-- ============================================================================
-- Helpers: gather clips from current context
-- ============================================================================

local function get_context_and_clips()
    local focus_manager = require("ui.focus_manager")
    local panel = focus_manager.get_focused_panel and focus_manager.get_focused_panel()

    if panel == "timeline" then
        local timeline_state = require("ui.timeline.timeline_state")
        local clips = timeline_state.get_clips and timeline_state.get_clips() or {}
        -- Build clip_data from timeline clips
        local clip_data = {}
        for _, clip in ipairs(clips) do
            clip_data[#clip_data + 1] = {
                id = clip.id,
                name = clip.name or "",
                codec = clip.codec or "",
                fps = clip.fps_float or 0,
                duration = clip.duration_frames or clip.duration or 0,
                enabled = clip.enabled ~= false,
                volume = clip.volume or 1.0,
                timeline_start_frame = clip.timeline_start_frame or clip.timeline_start or 0,
                track_id = clip.track_id or "",
                source_in_frame = clip.source_in_frame or clip.source_in or 0,
                source_out_frame = clip.source_out_frame or clip.source_out or 0,
                duration_frames = clip.duration_frames or clip.duration or 0,
                properties = {},
            }
        end
        table.sort(clip_data, function(a, b)
            return a.timeline_start_frame < b.timeline_start_frame
        end)
        return "timeline", clip_data
    end

    -- Default to browser
    local project_browser = require("ui.project_browser")
    local clip_data = {}
    if project_browser.master_clips then
        for _, clip in ipairs(project_browser.master_clips) do
            local media = clip.media or (clip.media_id and project_browser.media_map[clip.media_id]) or {}
            clip_data[#clip_data + 1] = {
                id = clip.clip_id or clip.id,
                name = clip.name or media.name or "",
                codec = clip.codec or media.codec or "",
                fps = clip.fps_float or 0,
                duration = clip.duration or 0,
                enabled = clip.enabled ~= false,
                volume = clip.volume or 1.0,
                width = clip.width or media.width or 0,
                height = clip.height or media.height or 0,
                audio_channels = media.audio_channels or 0,
                audio_sample_rate = media.audio_sample_rate or 0,
                properties = {},
            }
        end
    end
    return "browser", clip_data
end

local function select_clip_in_browser(clip_id)
    local project_browser = require("ui.project_browser")
    if project_browser.master_clip_map then
        local clip = project_browser.master_clip_map[clip_id]
        if clip and clip.tree_id then
            local qt = require("core.qt_constants")
            qt.CONTROL.SET_TREE_SELECTION(project_browser.tree, {clip.tree_id})
            qt.CONTROL.SCROLL_TO_TREE_ITEM(project_browser.tree, clip.tree_id)
        end
    end
end

local function navigate_timeline_to_clip(clip_id, clip_data)
    local timeline_state = require("ui.timeline.timeline_state")
    for _, clip in ipairs(clip_data) do
        if clip.id == clip_id then
            if timeline_state.set_playhead_position then
                timeline_state.set_playhead_position(clip.timeline_start_frame)
            end
            if timeline_state.set_selection then
                timeline_state.set_selection({{id = clip_id}})
            end
            break
        end
    end
end

-- ============================================================================
-- Command executors
-- ============================================================================

function M.register(command_executors, _, _, _)

    -- ========================================================================
    -- Find: open find dialog, gather clips from context
    -- ========================================================================
    command_executors["Find"] = function(_)
        local context, clips = get_context_and_clips()

        if #clips == 0 then
            log.warn("Find: no clips in current context")
            return {success = true, match_count = 0}
        end

        local ui_state = require("ui.ui_state")
        local parent = ui_state.get_main_window and ui_state.get_main_window() or nil
        local find_dialog = require("ui.find_dialog")

        local function on_find(result)
            if not result or not result.current_match then return end
            if context == "timeline" then
                navigate_timeline_to_clip(result.current_match, clips)
            else
                select_clip_in_browser(result.current_match)
            end
        end

        local function on_navigate(clip_id, _)
            if context == "timeline" then
                navigate_timeline_to_clip(clip_id, clips)
            else
                select_clip_in_browser(clip_id)
            end
        end

        local function save_selection()
            if context == "browser" then
                local pb = require("ui.project_browser")
                local sel = {}
                for _, item in ipairs(pb.selected_items or {}) do
                    sel[#sel + 1] = item.clip_id or item.id
                end
                return sel
            end
            return {}
        end

        local function on_restore(prev)
            if context == "browser" and prev and #prev > 0 then
                -- Restore previous browser selection
                select_clip_in_browser(prev[1])
            end
        end

        local result = find_dialog.show({
            clips = clips,
            context = context,
            parent = parent,
            on_find = on_find,
            on_navigate = on_navigate,
            save_selection = save_selection,
            on_restore_selection = on_restore,
        })

        -- If user clicked "Find & Replace...", open that dialog
        if result and result.action == "replace" then
            command_executors["FindReplace"](_)
        end

        return {success = true}
    end

    -- ========================================================================
    -- FindNext / FindPrevious: cycle through existing matches
    -- ========================================================================
    command_executors["FindNext"] = function(_)
        if not find_state.is_active() then
            log.warn("FindNext: no active find session")
            return {success = false, error_message = "No active find session"}
        end
        find_state.next()
        local match_id = find_state.get_current_match()
        if match_id then
            -- Try to navigate to match in whatever context is active
            local focus_manager = require("ui.focus_manager")
            local panel = focus_manager.get_focused_panel and focus_manager.get_focused_panel()
            if panel == "timeline" then
                local _, clips = get_context_and_clips()
                navigate_timeline_to_clip(match_id, clips)
            else
                select_clip_in_browser(match_id)
            end
        end
        return {success = true, current_match = match_id}
    end

    command_executors["FindPrevious"] = function(_)
        if not find_state.is_active() then
            log.warn("FindPrevious: no active find session")
            return {success = false, error_message = "No active find session"}
        end
        find_state.previous()
        local match_id = find_state.get_current_match()
        if match_id then
            local focus_manager = require("ui.focus_manager")
            local panel = focus_manager.get_focused_panel and focus_manager.get_focused_panel()
            if panel == "timeline" then
                local _, clips = get_context_and_clips()
                navigate_timeline_to_clip(match_id, clips)
            else
                select_clip_in_browser(match_id)
            end
        end
        return {success = true, current_match = match_id}
    end

    -- ========================================================================
    -- FindReplace: open find & replace dialog
    -- ========================================================================
    command_executors["FindReplace"] = function(_)
        local context, clips = get_context_and_clips()

        if #clips == 0 then
            log.warn("FindReplace: no clips in current context")
            return {success = true}
        end

        local timeline_state = require("ui.timeline.timeline_state")
        local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or nil
        assert(project_id, "FindReplace: no project open")

        local ui_state = require("ui.ui_state")
        local parent = ui_state.get_main_window and ui_state.get_main_window() or nil
        local find_dialog = require("ui.find_dialog")

        local function on_find(find_result)
            if not find_result or not find_result.current_match then return end
            if context == "timeline" then
                navigate_timeline_to_clip(find_result.current_match, clips)
            else
                select_clip_in_browser(find_result.current_match)
            end
        end

        local function on_navigate(clip_id, _)
            if context == "timeline" then
                navigate_timeline_to_clip(clip_id, clips)
            else
                select_clip_in_browser(clip_id)
            end
        end

        find_dialog.show({
            clips = clips,
            context = context,
            project_id = project_id,
            parent = parent,
            show_replace = true,
            on_find = on_find,
            on_navigate = on_navigate,
        })

        return {success = true}
    end

    -- ========================================================================
    -- ClearFind: clear find state, restore selection
    -- ========================================================================
    command_executors["ClearFind"] = function(_)
        local prev = find_state.get_previous_selection()
        find_state.clear()
        if prev and #prev > 0 then
            select_clip_in_browser(prev[1])
        end
        return {success = true}
    end

    -- Style B: multi-command registration
    return {
        ["Find"] = {executor = command_executors["Find"], spec = SPEC_FIND},
        ["FindNext"] = {executor = command_executors["FindNext"], spec = SPEC_FIND_NEXT},
        ["FindPrevious"] = {executor = command_executors["FindPrevious"], spec = SPEC_FIND_NEXT},
        ["FindReplace"] = {executor = command_executors["FindReplace"], spec = SPEC_FIND},
        ["ClearFind"] = {executor = command_executors["ClearFind"], spec = SPEC_FIND_NEXT},
    }
end

return M
