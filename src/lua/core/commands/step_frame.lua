-- @file step_frame.lua
--
-- StepFrame: non-undoable command to advance/retreat the playhead by 1 frame
-- (or 1 second with shift).
--
-- Mode-agnostic: uses the active SequenceView. seek_to_frame() displays the
-- frame via Renderer and updates the view's playhead.
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

        local pm = require('ui.panel_manager')
        local sv = pm.get_active_sequence_view()
        assert(sv and sv.sequence_id, "StepFrame: no sequence loaded in active view")
        local engine = sv.engine

        local shift = args.shift and true or false
        local current_frame = engine:get_position()

        assert(engine.fps_den > 0,
            string.format("StepFrame: engine.fps_den must be > 0, got %s", tostring(engine.fps_den)))
        local fps_float = engine.fps_num / engine.fps_den
        local step_frames = shift and math.max(1, math.floor(fps_float + 0.5)) or 1

        local new_frame
        if direction < 0 then
            new_frame = math.max(0, current_frame - step_frames)
        else
            new_frame = current_frame + step_frames
        end

        sv:seek_to_frame(new_frame)

        if engine.play_frame_audio then
            engine:play_frame_audio(new_frame)
        end

        return true
    end

    return {
        executor = command_executors["StepFrame"],
        spec = SPEC,
    }
end

return M
