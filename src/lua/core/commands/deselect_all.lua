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
-- Size: ~26 LOC
-- Volatility: unknown
--
-- @file deselect_all.lua
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
    command_executors["DeselectAll"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing DeselectAll command")
        end

        if args.dry_run then
            return true
        end

        local current_clips = timeline_state.get_selected_clips() or {}
        local current_edges = timeline_state.get_selected_edges() or {}

        if #current_clips == 0 and #current_edges == 0 then
            print("DeselectAll: nothing currently selected")
        end

        timeline_state.set_selection({})
        timeline_state.clear_edge_selection()

        print("✅ Deselected all clips and edges")
        return true
    end

    return {
        executor = command_executors["DeselectAll"],
        spec = SPEC,
    }
end

return M
