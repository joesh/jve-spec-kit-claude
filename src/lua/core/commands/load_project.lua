local M = {}
local log = require("core.logger").for_area("commands")
local Project = require('models.project')


local SPEC = {
    args = {
        project_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["LoadProject"] = function(command)
        local args = command:get_all_parameters()
        log.event("Executing LoadProject")

        local project_id = args.project_id
        if not project_id or project_id == "" then
            set_last_error("LoadProject: missing project_id")
            return false
        end

        local project = Project.load(project_id, db)
        if not project or project.id == "" then
            log.error("Failed to load project: %s", project_id)
            return false
        end

        log.event("Loaded project: %s", project.name)
        return true
    end

    return {
        executor = command_executors["LoadProject"],
        spec = SPEC,
    }
end

return M