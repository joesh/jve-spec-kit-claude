local M = {}
local log = require("core.logger").for_area("commands")
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
    command_executors["DeselectAll"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            log.event("Executing DeselectAll")
        end

        if args.dry_run then
            return true
        end

        local current_clips = timeline_state.get_selected_clips() or {}
        local current_edges = timeline_state.get_selected_edges() or {}

        if #current_clips == 0 and #current_edges == 0 then
            log.event("DeselectAll: nothing currently selected")
        end

        timeline_state.set_selection({})
        timeline_state.clear_edge_selection()
        if timeline_state.clear_gap_selection then
            timeline_state.clear_gap_selection()
        end

        log.event("Deselected all clips, edges, and gaps")
        return true
    end

    return {
        executor = command_executors["DeselectAll"],
        spec = SPEC,
    }
end

return M
