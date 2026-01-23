--- SetSelection Command - Persist timeline selection state
--
-- @file set_selection.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true, kind = "string" },
        sequence_id = { required = true, kind = "string" },
        selected_clip_ids_json = { required = true, kind = "string" },
        selected_edge_infos_json = { required = true, kind = "string" },
    },
}

function M.register(executors, undoers, db)
    executors["SetSelection"] = function(command)
        local args = command:get_all_parameters()
        local Sequence = require("models.sequence")
        local sequence = Sequence.load(args.sequence_id)
        if not sequence then
            return { success = false, error_message = "SetSelection: sequence not found" }
        end
        sequence.selected_clip_ids_json = args.selected_clip_ids_json
        sequence.selected_edge_infos_json = args.selected_edge_infos_json
        if not sequence:save() then
            return { success = false, error_message = "SetSelection: failed to save" }
        end
        return { success = true }
    end

    return {
        ["SetSelection"] = { executor = executors["SetSelection"], spec = SPEC },
    }
end

return M
