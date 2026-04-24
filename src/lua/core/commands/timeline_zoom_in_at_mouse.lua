--- TimelineZoomInAtMouse command — zoom in with the pointer frame as anchor.
--
-- Unlike TimelineZoomIn (which lets the viewport anchor default to playhead
-- if visible else viewport center), this command reads the timeline's
-- last-known pointer frame and holds it at the same pixel fraction.
--
-- Fail-fast: if no pointer frame is tracked (mouse never over timeline),
-- the command errors. A silent fallback would mask the misuse.
--
-- @file timeline_zoom_in_at_mouse.lua
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
    command_executors["TimelineZoomInAtMouse"] = function(command)
        local args = command:get_all_parameters()

        if args.dry_run then
            return true
        end

        local timeline_state = require('ui.timeline.timeline_state')

        local anchor_frame = timeline_state.get_last_pointer_frame
            and timeline_state.get_last_pointer_frame() or nil
        if type(anchor_frame) ~= "number" then
            set_last_error("TimelineZoomInAtMouse: no pointer frame tracked")
            return false
        end

        local dur = timeline_state.get_viewport_duration()
        assert(type(dur) == "number", "TimelineZoomInAtMouse: viewport_duration must be integer frames")

        local new_dur = math.floor(dur * 0.5)
        new_dur = math.max(30, new_dur)

        timeline_state.set_viewport_duration(new_dur, {
            zoom_around = "frame",
            anchor_frame = anchor_frame,
        })

        local zoom_fit = require("core.commands.timeline_zoom_fit")
        zoom_fit.clear_toggle_state()
        return true
    end

    return {
        executor = command_executors["TimelineZoomInAtMouse"],
        spec = SPEC,
    }
end

return M
