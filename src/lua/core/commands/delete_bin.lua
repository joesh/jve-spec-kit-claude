local M = {}
local tag_service = require("core.tag_service")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DeleteBin"] = function(command)
        command:set_parameter("__skip_sequence_replay", true)
        local project_id = command:get_parameter("project_id") or "default_project"
        local bin_id = command:get_parameter("bin_id")
        if not bin_id or bin_id == "" then
            set_last_error("DeleteBin: Missing bin_id")
            return false
        end

        local ok, result = tag_service.remove_bin(project_id, bin_id)
        if not ok then
            set_last_error("DeleteBin: " .. tostring(result))
            return false
        end

        command:set_parameter("deleted_bin_definition", result.definition)
        command:set_parameter("child_parent_snapshot", result.child_snapshot)
        command:set_parameter("bin_insert_index", result.insert_index)
        return true
    end

    command_undoers["DeleteBin"] = function(command)
        local project_id = command:get_parameter("project_id") or "default_project"
        local target_bin = command:get_parameter("deleted_bin_definition")
        if not target_bin then
            set_last_error("UndoDeleteBin: Missing bin definition")
            return false
        end

        local child_snapshot = command:get_parameter("child_parent_snapshot") or {}
        local insert_index = command:get_parameter("bin_insert_index")

        local ok, err = tag_service.restore_bin(project_id, target_bin, insert_index, child_snapshot)
        if not ok then
            set_last_error("UndoDeleteBin: " .. tostring(err))
            return false
        end

        return true
    end

    return {
        executor = command_executors["DeleteBin"],
        undoer = command_undoers["DeleteBin"],
    }
end

return M
