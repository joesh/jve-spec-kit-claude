--- TimelineZoomFit command - toggles between zoom-to-fit and previous viewport
--
-- Responsibilities:
-- - Zoom viewport to fit all clips with 10% buffer
-- - Toggle back to previous viewport when called again
--
-- @file timeline_zoom_fit.lua
local M = {}

-- Module-level toggle state (persists between calls for toggle behavior)
local zoom_fit_toggle_state = nil


local SPEC = {
    undoable = false,
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["TimelineZoomFit"] = function(command)
        local args = command:get_all_parameters()

        if args.dry_run then
            return true
        end

        -- If source monitor is focused, zoom-to-fit it instead
        local pm = require('ui.panel_manager')
        local active = pm.get_active_sequence_monitor()
        if active and active.view_id == "source_monitor" then
            active:zoom_to_fit()
            return true
        end

        local timeline_state
        do
            local ok, mod = pcall(require, 'ui.timeline.timeline_state')
            if ok then timeline_state = mod end
        end

        if not timeline_state then
            set_last_error("TimelineZoomFit: timeline state not available")
            return false
        end

        -- Toggle: restore saved viewport (snapshot was taken BEFORE zoom-to-fit)
        if zoom_fit_toggle_state then
            local prev = zoom_fit_toggle_state
            -- Duration first so start isn't clamped by the zoom-to-fit's wider viewport
            timeline_state.set_viewport_duration(prev.duration)
            timeline_state.set_viewport_start_time(prev.start_time)
            zoom_fit_toggle_state = nil
            return true
        end

        -- Snapshot current viewport BEFORE computing fit
        local saved_start = timeline_state.get_viewport_start_time()
        local saved_duration = timeline_state.get_viewport_duration()

        -- Compute fit bounds from media clips only (gaps are filler, not content)
        local clips = timeline_state.get_clips()
        local min_start, max_end = nil, nil

        for _, clip in ipairs(clips) do
            if clip.clip_kind ~= "gap" then
                local s = clip.timeline_start or clip.start_value
                local d = clip.duration
                if type(s) == "number" and type(d) == "number" then
                    local e = s + d
                    if not min_start or s < min_start then min_start = s end
                    if not max_end or e > max_end then max_end = e end
                end
            end
        end

        if not max_end or not min_start then
            set_last_error("TimelineZoomFit: no clips to fit")
            return false
        end

        -- Save pre-fit viewport for toggle restore
        zoom_fit_toggle_state = {
            start_time = saved_start,
            duration = saved_duration,
        }

        local ui_constants = require("core.ui_constants")
        local tc_floor = timeline_state.get_start_timecode_frame
            and timeline_state.get_start_timecode_frame() or 0
        local fit_start, fit_duration = ui_constants.compute_zoom_to_fit(min_start, max_end, tc_floor)

        timeline_state.set_viewport_duration(fit_duration)
        timeline_state.set_viewport_start_time(fit_start)
        return true
    end

    return {
        executor = command_executors["TimelineZoomFit"],
        spec = SPEC,
    }
end

-- Clear toggle state (sequence change, or any non-fit viewport change)
function M.clear_toggle_state()
    zoom_fit_toggle_state = nil
end

return M
