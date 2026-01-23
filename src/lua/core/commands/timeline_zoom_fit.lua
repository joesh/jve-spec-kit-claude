--- TimelineZoomFit command - toggles between zoom-to-fit and previous viewport
--
-- Responsibilities:
-- - Zoom viewport to fit all clips with 10% buffer
-- - Toggle back to previous viewport when called again
--
-- @file timeline_zoom_fit.lua
local M = {}
local Rational = require('core.rational')

-- Module-level toggle state (persists between calls for toggle behavior)
local zoom_fit_toggle_state = nil

local function snapshot_viewport(state)
    local snapshot = {}
    if state.get_viewport_duration then
        local ok, dur = pcall(state.get_viewport_duration)
        if ok then snapshot.duration = dur end
    end
    if state.get_viewport_start_time then
        local ok, start = pcall(state.get_viewport_start_time)
        if ok then snapshot.start_time = start end
    end
    return snapshot
end

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

        local timeline_state
        do
            local ok, mod = pcall(require, 'ui.timeline.timeline_state')
            if ok then timeline_state = mod end
        end

        if not timeline_state then
            set_last_error("TimelineZoomFit: timeline state not available")
            return false
        end

        local snapshot = snapshot_viewport(timeline_state)

        -- Toggle: if we have a previous view saved, restore it
        if zoom_fit_toggle_state and zoom_fit_toggle_state.previous_view then
            local prev = zoom_fit_toggle_state.previous_view
            local restore_duration = prev.duration
            if not restore_duration and timeline_state.get_viewport_duration then
                local ok, current_duration = pcall(timeline_state.get_viewport_duration)
                if ok then
                    restore_duration = current_duration
                end
            end

            if timeline_state.set_viewport_duration then
                timeline_state.set_viewport_duration(restore_duration)
            end

            if timeline_state.get_playhead_position and timeline_state.set_viewport_start_time then
                local playhead = timeline_state.get_playhead_position()
                if playhead then
                    local half_dur
                    if type(restore_duration) == "table" and restore_duration.frames then
                        half_dur = restore_duration / 2
                    else
                        half_dur = (restore_duration or 1000) / 2
                    end
                    timeline_state.set_viewport_start_time(playhead - half_dur)
                end
            end

            zoom_fit_toggle_state = nil
            print("🔄 Zoom fit toggle: restored view around playhead")
            return true
        end

        -- Get all clips to calculate bounds
        local clips = {}
        if timeline_state.get_clips then
            local ok, clip_list = pcall(timeline_state.get_clips)
            if ok and type(clip_list) == "table" then
                clips = clip_list
            end
        end

        local min_start = nil
        local max_end_time = nil

        for _, clip in ipairs(clips) do
            local start_val = clip.timeline_start or clip.start_value
            local dur_val = clip.duration

            if type(start_val) == "number" then start_val = Rational.from_seconds(start_val/1000.0) end
            if type(dur_val) == "number" then dur_val = Rational.from_seconds(dur_val/1000.0) end

            if start_val and dur_val then
                local end_val = start_val + dur_val

                if not min_start or start_val < min_start then
                    min_start = start_val
                end
                if not max_end_time or end_val > max_end_time then
                    max_end_time = end_val
                end
            end
        end

        if not max_end_time or not min_start then
            zoom_fit_toggle_state = nil
            set_last_error("TimelineZoomFit: no clips to fit")
            return false
        end

        zoom_fit_toggle_state = {
            previous_view = snapshot,
        }

        local duration = max_end_time - min_start
        local buffer = duration / 10
        local fit_duration = duration + buffer

        if timeline_state.set_viewport_duration then
            timeline_state.set_viewport_duration(fit_duration)
        end
        if timeline_state.set_viewport_start_time then
            timeline_state.set_viewport_start_time(min_start)
        end

        print(string.format("🔍 Zoomed to fit: %s visible (buffered)", tostring(fit_duration)))
        return true
    end

    return {
        executor = command_executors["TimelineZoomFit"],
        spec = SPEC,
    }
end

-- Allow clearing toggle state (for tests or when sequence changes)
function M.clear_toggle_state()
    zoom_fit_toggle_state = nil
end

return M
