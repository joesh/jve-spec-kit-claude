local M = {}
local timeline_state = require('ui.timeline.timeline_state')
local Signals = require("core.signals")


local SPEC = {
    undoable = false,
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToNextEdit"] = function(command)
        local args = command:get_all_parameters()

        local pm = require('ui.panel_manager')
        local sv = pm.get_active_sequence_monitor()
        assert(sv and sv.sequence_id, "GoToNextEdit: no sequence loaded in active view")

        -- Source monitor: "next edit" = go to end of clip
        if sv.view_id == "source_monitor" then
            if not args.dry_run then
                if sv.engine:is_playing() then sv.engine:stop() end
                sv:seek_to_frame(sv.total_frames)
            end
            return true
        end

        -- Timeline: load everything from sv.sequence_id (the actual
        -- write target). Symmetric with GoToPrevEdit — see comment
        -- there for why timeline_state is wrong here.
        local Sequence = require("models.sequence")
        local sequence = assert(Sequence.load(sv.sequence_id),
            "GoToNextEdit: sequence not found: " .. tostring(sv.sequence_id))
        local points = sequence:edit_points()
        local playhead = sequence.playhead_position
        assert(type(playhead) == "number",
            "GoToNextEdit: playhead_position must be integer frames")

        local target = playhead
        for _, point in ipairs(points) do
            if point > playhead then
                target = point
                break
            end
        end

        if args.dry_run then
            return true, { target = target }
        end

        if sv.engine:is_playing() then
            sv.engine:stop()
        end

        if target ~= playhead then
            sequence.playhead_position = target
            assert(sequence:save(), "GoToNextEdit: failed to save")
            Signals.emit("playhead_changed", sv.sequence_id, target)
            timeline_state.surface_playhead()
        end
        return true
    end

    return {
        executor = command_executors["GoToNextEdit"],
        spec = SPEC,
    }
end

return M
