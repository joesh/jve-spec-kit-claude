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
-- Size: ~25 LOC
-- Volatility: unknown
--
-- @file create_project.lua
local M = {}
local Project = require('models.project')

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["CreateProject"] = function(command)
        print("Executing CreateProject command")

        local name = command:get_parameter("name")
        if not name or name == "" then
            print("WARNING: CreateProject: Missing required 'name' parameter")
            return false
        end

        local project = Project.create(name)

        command:set_parameter("project_id", project.id)

        if project:save(db) then
            print(string.format("Created project: %s with ID: %s", name, project.id))
            return true
        else
            print(string.format("Failed to save project: %s", name))
            return false
        end
    end

    -- No undo for CreateProject currently defined in source
    return {
        executor = command_executors["CreateProject"]
    }
end

return M
