local M = {}
local uuid = require("uuid")
local tag_service = require("core.tag_service")
local command_helper = require("core.command_helper")

    function M.register(command_executors, command_undoers, db, set_last_error)
        command_executors["NewBin"] = function(command)
            command:set_parameter("__skip_sequence_replay", true)
            local project_id = command:get_parameter("project_id")
            if not project_id or project_id == "" then
                set_last_error("NewBin: missing project_id")
                return false
            end
            local bin_name = command_helper.trim_string(command:get_parameter("name"))
            if bin_name == "" then
                bin_name = "New Bin"
            end

        local bin_id = command:get_parameter("bin_id")
        if not bin_id or bin_id == "" then
            bin_id = uuid.generate()
            command:set_parameter("bin_id", bin_id)
        end

        local ok, result = tag_service.create_bin(project_id, {
            id = bin_id,
            name = bin_name,
            parent_id = command:get_parameter("parent_id")
        })
        if not ok then
            set_last_error("NewBin: " .. tostring(result))
            return false
        end

        command:set_parameter("bin_definition", result)
        return true
    end

    command_undoers["NewBin"] = function(command)
        local project_id = command:get_parameter("project_id")
        if not project_id or project_id == "" then
            set_last_error("UndoNewBin: missing project_id")
            return false
        end
        local bin_id = command:get_parameter("bin_id")
        if not bin_id or bin_id == "" then
            set_last_error("UndoNewBin: Missing bin_id parameter")
            return false
        end

        local ok, err = tag_service.remove_bin(project_id, bin_id)
        if not ok then
            set_last_error("UndoNewBin: " .. tostring(err))
            return false
        end

        return true
    end

    return {
        executor = command_executors["NewBin"],
        undoer = command_undoers["NewBin"],
    }
end

return M
