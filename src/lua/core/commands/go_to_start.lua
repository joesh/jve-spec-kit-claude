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


local SPEC = {
    undoable = false,
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

        -- Stop playback before navigating (NLE convention)
        local pm = require('ui.panel_manager')
        local sv = pm.get_active_sequence_view()
        if sv and sv.engine:is_playing() then
            sv.engine:stop()
        end

        timeline_state.set_playhead_position(0)
        print("✅ Moved playhead to start")
        return true
    end

    return {
        executor = command_executors["GoToStart"],
        spec = SPEC,
    }
end

return M
