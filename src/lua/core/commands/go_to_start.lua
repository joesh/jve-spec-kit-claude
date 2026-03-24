--- GoToStart: move playhead to frame 0 in the active monitor
--
-- Respects focus: operates on whichever SequenceMonitor (source or timeline)
-- is currently active via panel_manager.
--
-- @file go_to_start.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToStart"] = function(command)
        local args = command:get_all_parameters()

        if args.dry_run then
            return true
        end

        local pm = require('ui.panel_manager')
        local sv = pm.get_active_sequence_monitor()
        assert(sv and sv.sequence_id, "GoToStart: no sequence loaded in active view")

        if sv.engine:is_playing() then
            sv.engine:stop()
        end

        -- Each sequence knows its own start TC (0 for master clips, DRP value for timelines)
        local start_frame = 0
        if sv.sequence then
            start_frame = sv.sequence.start_timecode_frame or 0
        end
        sv:seek_to_frame(start_frame)
        return true
    end

    return {
        executor = command_executors["GoToStart"],
        spec = SPEC,
    }
end

return M
