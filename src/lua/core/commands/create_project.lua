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


local SPEC = {
    args = {
        name = { required = true },
        project_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["CreateProject"] = function(command)
        local args = command:get_all_parameters()
        print("Executing CreateProject command")

        local name = args.name
        local project_id = args.project_id
        -- Project-level fps-mismatch policy default for new projects.
        -- Conventional first-landing default per spec FR-015 commentary;
        -- editable later via SetFpsMismatchPolicy (T064, scope='project').
        local fps_policy = args.fps_mismatch_policy or "resample"
        local project = Project.create(name, {
            id = project_id,
            fps_mismatch_policy = fps_policy,
        })

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
        executor = command_executors["CreateProject"],
        spec = SPEC,
    }
end

return M