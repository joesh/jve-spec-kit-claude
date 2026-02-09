--- TimelineZoomIn command - zooms in the timeline viewport
--
-- Responsibilities:
-- - Reduce viewport duration by 20% (multiply by 0.8)
-- - Enforce minimum 30 frames viewport
--
-- @file timeline_zoom_in.lua
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
        assert(type(dur) == "number", "TimelineZoomIn: viewport_duration must be integer frames")

        -- Reduce by 20%, enforce minimum 30 frames (~1 second at 30fps)
        local new_dur = math.floor(dur * 0.8)
        new_dur = math.max(30, new_dur)

        timeline_state.set_viewport_duration(new_dur)
        return true
    end

    return {
        executor = command_executors["TimelineZoomIn"],
        spec = SPEC,
    }
end

return M
