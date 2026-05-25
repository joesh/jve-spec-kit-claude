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
    command_executors["GoToPrevEdit"] = function(command)
        local args = command:get_all_parameters()

        local pm = require('ui.panel_manager')
        local sv = pm.get_active_sequence_monitor()
        assert(sv and sv.sequence_id, "GoToPrevEdit: no sequence loaded in active view")

        -- Source monitor: "prev edit" = go to start of clip
        if sv.view_id == "source_monitor" then
            if not args.dry_run then
                if sv.engine:is_playing() then sv.engine:stop() end
                sv:seek_to_frame(0)
            end
            return true
        end

        -- Timeline: load everything from sv.sequence_id (the actual
        -- write target). timeline_state reflects the displayed tab,
        -- which may differ from sv.sequence_id (e.g., timeline focus
        -- while source tab is displayed) — and would yield a target
        -- frame outside sv's content range, tripping seek asserts in
        -- every playhead_changed listener.
        local Sequence = require("models.sequence")
        local sequence = assert(Sequence.load(sv.sequence_id),
            "GoToPrevEdit: sequence not found: " .. tostring(sv.sequence_id))
        local points = sequence:edit_points()
        local playhead = sequence.playhead_position
        assert(type(playhead) == "number",
            "GoToPrevEdit: playhead_position must be integer frames")

        local target = playhead
        for i = #points, 1, -1 do
            local point = points[i]
            if point < playhead then
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
            assert(sequence:save(), "GoToPrevEdit: failed to save")
            Signals.emit("playhead_changed", sv.sequence_id, target)
            timeline_state.surface_playhead()
        end
        return true
    end

    return {
        executor = command_executors["GoToPrevEdit"],
        spec = SPEC,
    }
end

return M
