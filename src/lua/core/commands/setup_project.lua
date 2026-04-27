local M = {}
local log = require("core.logger").for_area("commands")
local Project = require('models.project')
local json = require("dkjson")


local SPEC = {
    args = {
        project_id = { required = true },
        settings = {},
    },
    persisted = {
        previous_settings = {},
    },
}


function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SetupProject"] = function(command)
        local args = command:get_all_parameters()
        log.event("Executing SetupProject")

        local project = Project.load(args.project_id, db)
        if not project or project.id == "" then
            log.warn("SetupProject: project not found: %s",
                tostring(args.project_id))
            return false
        end

        command:set_parameter("previous_settings", project.settings)
        project.settings = json.encode(args.settings)

        if project:save(db) then
            log.event("Applied settings to project: %s", args.project_id)
            return true
        else
            set_last_error("Failed to save project settings")
            return false
        end
    end

    -- No undo defined in original source for SetupProject, assumed to be setup-only
    return {
        executor = command_executors["SetupProject"],
        spec = SPEC,
    }
end

return M
