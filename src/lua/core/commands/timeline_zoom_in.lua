--- TimelineZoomIn command - zooms in the timeline viewport
--
-- Responsibilities:
-- - Reduce viewport duration by 20% (multiply by 0.8)
-- - Enforce minimum 1 second viewport
--
-- @file timeline_zoom_in.lua
local M = {}
local Rational = require('core.rational')

local SPEC = {
    undoable = false,
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["TimelineZoomIn"] = function(command)
        local args = command:get_all_parameters()

        if args.dry_run then
            return true
        end

        local timeline_state
        do
            local ok, mod = pcall(require, 'ui.timeline.timeline_state')
            if ok then timeline_state = mod end
        end

        if not timeline_state or not timeline_state.get_viewport_duration or not timeline_state.set_viewport_duration then
            set_last_error("TimelineZoomIn: timeline state not available")
            return false
        end

        local dur = timeline_state.get_viewport_duration()
        local new_dur = dur * 0.8

        -- Enforce minimum 1 second viewport
        if type(new_dur) == "table" and new_dur.frames then
            local min_dur = Rational.from_seconds(1.0, new_dur.fps_numerator, new_dur.fps_denominator)
            new_dur = Rational.max(min_dur, new_dur)
        else
            new_dur = math.max(1000, new_dur)
        end

        timeline_state.set_viewport_duration(new_dur)
        return true
    end

    return {
        executor = command_executors["TimelineZoomIn"],
        spec = SPEC,
    }
end

return M
