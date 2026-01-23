--- SetMarks Command - Persist in/out markers
--
-- @file set_marks.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true, kind = "string" },
        sequence_id = { required = true, kind = "string" },
        mark_in = { kind = "number" },   -- nil clears the mark
        mark_out = { kind = "number" },  -- nil clears the mark
    },
}

function M.register(executors, undoers, db)
    executors["SetMarks"] = function(command)
        local args = command:get_all_parameters()
        local Sequence = require("models.sequence")
        local sequence = Sequence.load(args.sequence_id)
        if not sequence then
            return { success = false, error_message = "SetMarks: sequence not found" }
        end
        sequence.mark_in = args.mark_in
        sequence.mark_out = args.mark_out
        if not sequence:save() then
            return { success = false, error_message = "SetMarks: failed to save" }
        end
        return { success = true }
    end

    return {
        ["SetMarks"] = { executor = executors["SetMarks"], spec = SPEC },
    }
end

return M
