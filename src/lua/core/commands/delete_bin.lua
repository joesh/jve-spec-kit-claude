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
-- Size: ~51 LOC
-- Volatility: unknown
--
-- @file delete_bin.lua
local M = {}
local tag_service = require("core.tag_service")


local SPEC = {
    args = {
        bin_id = { required = true },
        bin_insert_index = {},
        child_parent_snapshot = {},
        deleted_bin_definition = { required = true },
        project_id = { required = true },
    }
}

    function M.register(command_executors, command_undoers, db, set_last_error)
        command_executors["DeleteBin"] = function(command)
            local args = command:get_all_parameters()
            command:set_parameter("__skip_sequence_replay", true)

        local ok, result = tag_service.remove_bin(args.project_id, args.bin_id)
        if not ok then
            set_last_error("DeleteBin: " .. tostring(result))
            return false
        end

        command:set_parameters({
            ["deleted_bin_definition"] = result.definition,
            ["child_parent_snapshot"] = result.child_snapshot,
            ["bin_insert_index"] = result.insert_index,
        })
        return true
    end

    command_undoers["DeleteBin"] = function(command)
        local args = command:get_all_parameters()

        local child_snapshot = args.child_parent_snapshot or {}


        local ok, err = tag_service.restore_bin(args.project_id, args.deleted_bin_definition, args.bin_insert_index, child_snapshot)
        if not ok then
            set_last_error("UndoDeleteBin: " .. tostring(err))
            return false
        end

        return true
    end

    return {
        executor = command_executors["DeleteBin"],
        undoer = command_undoers["DeleteBin"],
        spec = SPEC,
    }
end

return M
