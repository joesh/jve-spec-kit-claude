--- SetPlayhead Command - Persist playhead position
--
-- @file set_playhead.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true, kind = "string" },
        sequence_id = { required = true, kind = "string" },
        playhead_position = { required = true },
    },
}

function M.register(executors, undoers, db)
    executors["SetPlayhead"] = function(command)
        local args = command:get_all_parameters()
        local Sequence = require("models.sequence")
        local sequence = Sequence.load(args.sequence_id)
        if not sequence then
            return { success = false, error_message = "SetPlayhead: sequence not found" }
        end
        sequence.playhead_position = args.playhead_position
        if not sequence:save() then
            return { success = false, error_message = "SetPlayhead: failed to save" }
        end
        return { success = true }
    end

    return {
        ["SetPlayhead"] = { executor = executors["SetPlayhead"], spec = SPEC },
    }
end

return M
