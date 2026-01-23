--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~30 LOC
-- Volatility: unknown
--
-- @file go_to_start.lua
local M = {}
local timeline_state = require('ui.timeline.timeline_state')
local sequence_frame_rate = require('core.utils.sequence_frame_rate')
local Rational = require('core.rational')


local SPEC = {
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToStart"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing GoToStart command")
        end

        if args.dry_run then
            return true
        end

        -- Use current sequence frame rate for zero
        local fps_num, fps_den = sequence_frame_rate.require_sequence_frame_rate(timeline_state, "GoToStart")

        timeline_state.set_playhead_position(Rational.new(0, fps_num, fps_den))
        print("✅ Moved playhead to start")
        return true
    end

    return {
        executor = command_executors["GoToStart"],
        spec = SPEC,
    }
end

return M
