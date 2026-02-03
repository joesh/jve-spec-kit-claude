--- SetViewport Command - Persist viewport bounds
--
-- @file set_viewport.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true, kind = "string" },
        sequence_id = { required = true, kind = "string" },
        viewport_start_time = { required = true },
        viewport_duration = { required = true },
    },
}

function M.register(executors, undoers, db)
    executors["SetViewport"] = function(command)
        local args = command:get_all_parameters()
        local Sequence = require("models.sequence")
        local sequence = Sequence.load(args.sequence_id)
        if not sequence then
            return { success = false, error_message = "SetViewport: sequence not found" }
        end
        sequence.viewport_start_time = args.viewport_start_time
        sequence.viewport_duration = args.viewport_duration
        if not sequence:save() then
            return { success = false, error_message = "SetViewport: failed to save" }
        end
        return { success = true }
    end

    return {
        ["SetViewport"] = { executor = executors["SetViewport"], spec = SPEC },
    }
end

return M
