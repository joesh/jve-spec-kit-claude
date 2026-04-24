--- TimelineZoomOutAtMouse command — zoom out with the pointer frame as anchor.
--
-- Sibling of TimelineZoomInAtMouse. See that file for the rationale.
--
-- @file timeline_zoom_out_at_mouse.lua
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
    command_executors["TimelineZoomOutAtMouse"] = function(command)
        local args = command:get_all_parameters()

        if args.dry_run then
            return true
        end

        local timeline_state = require('ui.timeline.timeline_state')

        local anchor_frame = timeline_state.get_last_pointer_frame
            and timeline_state.get_last_pointer_frame() or nil
        if type(anchor_frame) ~= "number" then
            set_last_error("TimelineZoomOutAtMouse: no pointer frame tracked")
            return false
        end

        local dur = timeline_state.get_viewport_duration()
        assert(type(dur) == "number", "TimelineZoomOutAtMouse: viewport_duration must be integer frames")

        timeline_state.set_viewport_duration(math.floor(dur * 2.0), {
            zoom_around = "frame",
            anchor_frame = anchor_frame,
        })

        local zoom_fit = require("core.commands.timeline_zoom_fit")
        zoom_fit.clear_toggle_state()
        return true
    end

    return {
        executor = command_executors["TimelineZoomOutAtMouse"],
        spec = SPEC,
    }
end

return M
