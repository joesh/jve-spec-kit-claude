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

        -- End = first frame past content (exclusive out-point)
        assert(sv.total_frames > 0, "GoToEnd: total_frames must be > 0")
        local end_frame = sv.total_frames

        if args.dry_run then
            return true, { end_frame = end_frame }
        end

        if sv.engine:is_playing() then
            sv.engine:stop()
        end

        -- Update model — playhead_changed signal drives view (seek + viewport scroll)
        local Sequence = require("models.sequence")
        local sequence = Sequence.load(sv.sequence_id)
        assert(sequence, "GoToEnd: sequence not found: " .. tostring(sv.sequence_id))
        sequence.playhead_position = end_frame
        sequence:save()
        local Signals = require("core.signals")
        Signals.emit("playhead_changed", sv.sequence_id, end_frame)

        -- Scroll timeline viewport to keep playhead visible
        local timeline_state = require("ui.timeline.timeline_state")
        timeline_state.surface_playhead()
        return true
    end

    return {
        executor = command_executors["GoToEnd"],
        spec = SPEC,
    }
end

return M
