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
-- Size: ~57 LOC
-- Volatility: unknown
--
-- @file new_bin.lua
local M = {}
local tag_service = require("core.tag_service")
local command_helper = require("core.command_helper")


local SPEC = {
    args = {
        bin_id = { required = true, kind = "string" },
        name = { kind = "string" },
        parent_id = { kind = "string" },
        project_id = { required = true, kind = "string" },
    },
    persisted = {
        bin_definition = {},
    },

}
function M.register(command_executors, command_undoers, db, set_last_error)
        command_executors["NewBin"] = function(command)
            local args = command:get_all_parameters()
            command:set_parameter("__skip_sequence_replay", true)
            local bin_name = command_helper.trim_string(args.name)
            if bin_name == "" then
                bin_name = "New Bin"
            end
        local bin_id = args.bin_id

        local ok, result = tag_service.create_bin(args.project_id, {
            id = bin_id,
            name = bin_name,
            parent_id = args.parent_id
        })
        if not ok then
            set_last_error("NewBin: " .. tostring(result))
            return false
        end

        command:set_parameter("bin_definition", result)
        return true
    end

    command_undoers["NewBin"] = function(command)
        local args = command:get_all_parameters()

        local ok, err = tag_service.remove_bin(args.project_id, args.bin_id)
        if not ok then
            set_last_error("UndoNewBin: " .. tostring(err))
            return false
        end

        return true
    end

    return {
        executor = command_executors["NewBin"],
        undoer = command_undoers["NewBin"],
        spec = SPEC,
    }
end

return M
