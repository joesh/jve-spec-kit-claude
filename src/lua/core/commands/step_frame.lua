-- @file step_frame.lua
--
-- StepFrame: non-undoable command to advance/retreat the playhead by 1 frame
-- (or 1 second with shift).
--
-- Mode-agnostic: uses playback_controller's API which internally handles
-- timeline vs source mode. set_position() updates the model and triggers
-- viewer display in both modes.
local M = {}

local SPEC = {
    undoable = false,
    args = {
        direction = { required = true, kind = "number" },  -- 1=right, -1=left
        shift = { kind = "boolean" },                       -- true=1-second jumps
        project_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["StepFrame"] = function(command)
        local args = command:get_all_parameters()
        local direction = args.direction
        assert(direction == 1 or direction == -1,
            string.format("StepFrame: direction must be 1 or -1, got %s", tostring(direction)))

        local pc = require('core.playback.playback_controller')
        assert(pc.has_source(), "StepFrame: no playback source loaded")

        local shift = args.shift and true or false
        local current_frame = pc.get_position()

        local fps_float = (pc.fps_den > 0) and (pc.fps_num / pc.fps_den) or 30
        local step_frames = shift and math.max(1, math.floor(fps_float + 0.5)) or 1

        local new_frame
        if direction < 0 then
            new_frame = math.max(0, current_frame - step_frames)
        else
            new_frame = current_frame + step_frames
        end

        pc.set_position(new_frame)

        if pc.play_frame_audio then
            pc.play_frame_audio(new_frame)
        end

        return true
    end

    return {
        executor = command_executors["StepFrame"],
        spec = SPEC,
    }
end

return M
