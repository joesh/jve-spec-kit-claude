local M = {}
local log = require("core.logger").for_area("commands")
local Project = require('models.project')
local json = require("dkjson")


local SPEC = {
    args = {
        project_id = { required = true },
        settings = { required = true },
    },
    persisted = {
        previous_settings = {},
    },
}


function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SetupProject"] = function(command)
        local args = command:get_all_parameters()
        log.event("Executing SetupProject")

        assert(type(args.settings) == "table",
            string.format("SetupProject: args.settings must be a table, got %s",
                type(args.settings)))

        local project = Project.load(args.project_id, db)
        if not project or project.id == "" then
            log.warn("SetupProject: project not found: %s",
                tostring(args.project_id))
            return false
        end

        command:set_parameter("previous_settings", project.settings)
        -- 018 FR-028 / FR-036a: SetupProject MAY NOT destroy the
        -- infra-level keys (master_clock_hz, default_fps) that
        -- ensure_settings_json asserts on save. Merge user settings over
        -- the existing settings instead of clobbering.
        local prev = {}
        if type(project.settings) == "string" and project.settings ~= "" then
            local decoded = json.decode(project.settings)
            if type(decoded) == "table" then prev = decoded end
        end
        for k, v in pairs(args.settings) do
            prev[k] = v
        end
        project.settings = json.encode(prev)

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
