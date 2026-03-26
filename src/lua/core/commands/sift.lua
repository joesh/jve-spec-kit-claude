--- Sift commands: Sift, ExpandSift, NarrowSift, ClearSift, ShowTimelineIndex
--
-- Sift opens the sift dialog, gathers clips from browser.
-- Expand/Narrow/Clear operate on existing sift state.
-- ShowTimelineIndex opens the timeline index floating dialog.
--
-- @file sift.lua

local sift_commands = require("core.sift_commands")
local sift_state = require("core.sift_state")
local log = require("core.logger").for_area("ui")

local M = {}

local SPEC_SIFT = {
    undoable = false,
    args = {},
}

-- ============================================================================
-- Helpers
-- ============================================================================

local function get_browser_clips()
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
    return clip_data
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

-- ============================================================================
-- Command executors
-- ============================================================================

function M.register(command_executors, _, db, _)

    -- ========================================================================
    -- Sift: open sift dialog
    -- ========================================================================
    command_executors["Sift"] = function(_)
        local clips = get_browser_clips()
        local project_id = get_project_id()
        assert(project_id, "Sift: no project open")

        -- Open the unified Find & Filter dialog
        local find_dialog = require("ui.find_dialog")
        find_dialog.show({
            clips = clips,
            context = "browser",
            project_id = project_id,
        })

        return {success = true}
    end

    -- ========================================================================
    -- ExpandSift: open sift dialog in expand mode (or expand directly if
    -- column/operator/value provided via scripting)
    -- ========================================================================
    command_executors["ExpandSift"] = function(command)
        local args = command:get_all_parameters()
        if args.column and args.operator and args.value then
            -- Scripting path: expand directly
            local clips = get_browser_clips()
            local project_id = get_project_id()
            assert(project_id, "ExpandSift: no project open")
            assert(sift_state.is_active(), "ExpandSift: no active sift")
            sift_commands.expand_sift(clips,
                {column = args.column, operator = args.operator, value = args.value},
                db, project_id)
            refresh_browser()
            local eval = sift_state.evaluate(clips)
            return {success = true, visible_count = #eval.visible_ids}
        end
        -- UI path: open sift dialog (it handles the mode)
        return command_executors["Sift"](command)
    end

    -- ========================================================================
    -- NarrowSift
    -- ========================================================================
    command_executors["NarrowSift"] = function(command)
        local args = command:get_all_parameters()
        if args.column and args.operator and args.value then
            local clips = get_browser_clips()
            local project_id = get_project_id()
            assert(project_id, "NarrowSift: no project open")
            assert(sift_state.is_active(), "NarrowSift: no active sift")
            sift_commands.narrow_sift(clips,
                {column = args.column, operator = args.operator, value = args.value},
                db, project_id)
            refresh_browser()
            local eval = sift_state.evaluate(clips)
            return {success = true, visible_count = #eval.visible_ids}
        end
        return command_executors["Sift"](command)
    end

    -- ========================================================================
    -- ClearSift
    -- ========================================================================
    command_executors["ClearSift"] = function(_)
        local project_id = get_project_id()
        if project_id then
            sift_commands.clear_sift(db, project_id)
        else
            sift_state.clear()
        end
        refresh_browser()
        return {success = true}
    end

    -- ========================================================================
    -- ShowTimelineIndex: open timeline index floating dialog
    -- ========================================================================
    command_executors["ShowTimelineIndex"] = function(_)
        local timeline_state = require("ui.timeline.timeline_state")
        local clips = timeline_state.get_clips and timeline_state.get_clips() or {}

        if #clips == 0 then
            log.warn("ShowTimelineIndex: no clips in active timeline")
            return {success = true}
        end

        -- Build clip_data for timeline index
        local clip_data = {}
        for _, clip in ipairs(clips) do
            clip_data[#clip_data + 1] = {
                id = clip.id,
                name = clip.name or "",
                track_id = clip.track_id or "",
                timeline_start_frame = clip.timeline_start_frame or clip.timeline_start or 0,
                duration_frames = clip.duration_frames or clip.duration or 0,
                source_in_frame = clip.source_in_frame or clip.source_in or 0,
                source_out_frame = clip.source_out_frame or clip.source_out or 0,
            }
        end

        local timeline_index = require("ui.timeline_index")

        timeline_index.show({
            clips = clip_data,
            on_navigate = function(clip_id, frame)
                if timeline_state.set_playhead_position then
                    timeline_state.set_playhead_position(frame)
                end
                if timeline_state.set_selection then
                    timeline_state.set_selection({{id = clip_id}})
                end
            end,
        })

        return {success = true}
    end

    -- Style B: multi-command registration
    return {
        ["Sift"] = {executor = command_executors["Sift"], spec = SPEC_SIFT},
        ["ExpandSift"] = {executor = command_executors["ExpandSift"], spec = SPEC_SIFT},
        ["NarrowSift"] = {executor = command_executors["NarrowSift"], spec = SPEC_SIFT},
        ["ClearSift"] = {executor = command_executors["ClearSift"], spec = SPEC_SIFT},
        ["ShowTimelineIndex"] = {executor = command_executors["ShowTimelineIndex"], spec = SPEC_SIFT},
    }
end

return M
