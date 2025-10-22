-- Project and Sequence Management Commands
-- Extracted from command_manager.lua for Rule 2.27 compliance

local M = {}

-- Register project and sequence command executors
function M.register_executors(command_executors, command_undoers)

    -- CreateProject: Initialize new project
    command_executors["CreateProject"] = function(command)
        print("Executing CreateProject command")

        local name = command:get_parameter("name")
        if not name or name == "" then
            error("FATAL: CreateProject: Missing required 'name' parameter")
        end

        local Project = require('models.project')
        local project = Project.create(name)

        command:set_parameter("project_id", project.id)

        if not project:save(require("core.database").get_connection()) then
            error(string.format("FATAL: Failed to save project: %s", name))
        end

        print(string.format("Created project: %s with ID: %s", name, project.id))
        return true
    end

    -- LoadProject: Load existing project by ID
    command_executors["LoadProject"] = function(command)
        print("Executing LoadProject command")

        local project_id = command:get_parameter("project_id")
        if not project_id or project_id == "" then
            error("FATAL: LoadProject: Missing required 'project_id' parameter")
        end

        local Project = require('models.project')
        local db = require("core.database").get_connection()
        local project = Project.load(project_id, db)
        if not project or project.id == "" then
            error(string.format("FATAL: Failed to load project: %s", project_id))
        end

        print(string.format("Loaded project: %s", project.name))
        return true
    end

    -- CreateSequence: Initialize new sequence in project
    command_executors["CreateSequence"] = function(command)
        print("Executing CreateSequence command")

        local name = command:get_parameter("name")
        if not name or name == "" then
            error("FATAL: CreateSequence: Missing required 'name' parameter")
        end

        local project_id = command:get_parameter("project_id")
        if not project_id or project_id == "" then
            error("FATAL: CreateSequence: Missing required 'project_id' parameter")
        end

        local Sequence = require('models.sequence')
        local sequence = Sequence.create(name, project_id)

        command:set_parameter("sequence_id", sequence.id)

        local db = require("core.database").get_connection()
        if not sequence:save(db) then
            error(string.format("FATAL: Failed to save sequence: %s", name))
        end

        print(string.format("Created sequence: %s with ID: %s", name, sequence.id))
        return true
    end

    -- SetupProject: Initialize complete project structure
    command_executors["SetupProject"] = function(command)
        print("Executing SetupProject command")

        local name = command:get_parameter("name")
        if not name or name == "" then
            error("FATAL: SetupProject: Missing required 'name' parameter")
        end

        -- Create project
        local Project = require('models.project')
        local project = Project.create(name)
        local db = require("core.database").get_connection()

        if not project:save(db) then
            error(string.format("FATAL: Failed to save project: %s", name))
        end

        command:set_parameter("project_id", project.id)
        print(string.format("Created project: %s", project.name))

        -- Create default sequence
        local Sequence = require('models.sequence')
        local sequence = Sequence.create("Sequence 1", project.id)

        if not sequence:save(db) then
            error(string.format("FATAL: Failed to save default sequence for project: %s", name))
        end

        command:set_parameter("sequence_id", sequence.id)
        print(string.format("Created default sequence: %s", sequence.name))

        -- Create default tracks
        local Track = require('models.track')

        -- Video tracks (V1, V2, V3)
        for i = 1, 3 do
            local video_track = Track.create("V" .. i, "VIDEO", i, sequence.id)
            if not video_track:save(db) then
                error(string.format("FATAL: Failed to save video track V%d", i))
            end
            print(string.format("Created video track: V%d", i))
        end

        -- Audio tracks (A1, A2, A3)
        for i = 1, 3 do
            local audio_track = Track.create("A" .. i, "AUDIO", i, sequence.id)
            if not audio_track:save(db) then
                error(string.format("FATAL: Failed to save audio track A%d", i))
            end
            print(string.format("Created audio track: A%d", i))
        end

        print("Project setup complete")
        return true
    end
end

return M
