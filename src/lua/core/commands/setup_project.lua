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
-- Size: ~34 LOC
-- Volatility: unknown
--
-- @file setup_project.lua
local M = {}
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
        print("Executing SetupProject command")




        local project = Project.load(args.project_id, db)
        if not project or project.id == "" then
            print(string.format("WARNING: SetupProject: Project not found: %s", args.project_id))
            return false
        end

        -- Store previous settings for undo
        local previous_settings = project.settings
        command:set_parameter("previous_settings", previous_settings)

        -- Apply new settings
        local settings_json = json.encode(args.settings)
        project.settings = settings_json

        if project:save(db) then
            print(string.format("Applied settings to project: %s", args.project_id))
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
