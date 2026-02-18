--- GoToEnd: move playhead to the last frame in the active monitor
--
-- Respects focus: operates on whichever SequenceMonitor (source or timeline)
-- is currently active via panel_manager.
--
-- For timeline: last clip end. For source: total_frames.
--
-- @file go_to_end.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToEnd"] = function(command)
        local args = command:get_all_parameters()

        local pm = require('ui.panel_manager')
        local sv = pm.get_active_sequence_monitor()
        assert(sv and sv.sequence_id, "GoToEnd: no sequence loaded in active view")

        -- End = total frames in the monitor's loaded sequence
        local end_frame = sv.total_frames

        if args.dry_run then
            return true, { end_frame = end_frame }
        end

        if sv.engine:is_playing() then
            sv.engine:stop()
        end

        sv:seek_to_frame(end_frame)
        return true
    end

    return {
        executor = command_executors["GoToEnd"],
        spec = SPEC,
    }
end

return M
