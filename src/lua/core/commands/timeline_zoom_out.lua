--- TimelineZoomOut command - zooms out the timeline viewport
--
-- Responsibilities:
-- - Increase viewport duration by 25% (multiply by 1.25)
--
-- @file timeline_zoom_out.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["TimelineZoomOut"] = function(command)
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
            set_last_error("TimelineZoomOut: timeline state not available")
            return false
        end

        local dur = timeline_state.get_viewport_duration()
        timeline_state.set_viewport_duration(math.floor(dur * 1.25))
        return true
    end

    return {
        executor = command_executors["TimelineZoomOut"],
        spec = SPEC,
    }
end

return M
