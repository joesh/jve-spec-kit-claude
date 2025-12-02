local M = {}
local timeline_state = require('ui.timeline.timeline_state')
local Rational = require('core.rational')

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToStart"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing GoToStart command")
        end

        if dry_run then
            return true
        end

        -- Use current sequence frame rate for zero
        local fps_num = 30
        local fps_den = 1
        if timeline_state.get_sequence_frame_rate then
            local rate = timeline_state.get_sequence_frame_rate()
            if type(rate) == "table" and rate.fps_numerator then
                fps_num = rate.fps_numerator
                fps_den = rate.fps_denominator
            end
        end

        timeline_state.set_playhead_position(Rational.new(0, fps_num, fps_den))
        print("✅ Moved playhead to start")
        return true
    end

    return {
        executor = command_executors["GoToStart"]
    }
end

return M
