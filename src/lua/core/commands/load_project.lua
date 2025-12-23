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
-- Size: ~23 LOC
-- Volatility: unknown
--
-- @file load_project.lua
local M = {}
local Project = require('models.project')

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["LoadProject"] = function(command)
        print("Executing LoadProject command")

        local project_id = command:get_parameter("project_id")
        if not project_id or project_id == "" then
            print("WARNING: LoadProject: Missing required 'project_id' parameter")
            return false
        end

        local project = Project.load(project_id, db)
        if not project or project.id == "" then
            print(string.format("Failed to load project: %s", project_id))
            return false
        end

        print(string.format("Loaded project: %s", project.name))
        return true
    end

    return {
        executor = command_executors["LoadProject"]
    }
end

return M
