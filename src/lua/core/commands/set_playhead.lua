--- SetPlayhead Command - Persist playhead position + emit signal
--
-- @file set_playhead.lua
local M = {}
local Signals = require("core.signals")

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
        assert(args.sequence_id and args.sequence_id ~= "",
            "SetPlayhead: sequence_id is required")
        assert(type(args.playhead_position) == "number",
            "SetPlayhead: playhead_position must be a number")

        local Sequence = require("models.sequence")
        local sequence = Sequence.load(args.sequence_id)
        assert(sequence,
            "SetPlayhead: sequence not found: " .. tostring(args.sequence_id))

        sequence.playhead_position = args.playhead_position
        assert(sequence:save(), "SetPlayhead: failed to save")

        Signals.emit("playhead_changed", args.sequence_id, args.playhead_position)
        return { success = true }
    end

    return {
        ["SetPlayhead"] = { executor = executors["SetPlayhead"], spec = SPEC },
    }
end

return M
