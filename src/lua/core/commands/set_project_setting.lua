--- SetProjectSetting command - sets a project-level setting
--
-- Responsibilities:
-- - Persist project settings (viewport state, UI preferences, etc.)
-- - Non-undoable (UI preference, not document state)
-- - Scriptable for automation
--
-- @file set_project_setting.lua
local M = {}
local database = require("core.database")

local SPEC = {
    undoable = false,
    args = {
        key = { required = true, kind = "string" },
        value = {},  -- any JSON-serializable value, nil to delete
        project_id = { required = true, kind = "string" },
    },
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SetProjectSetting"] = function(command)
        local args = command:get_all_parameters()
        command:set_parameter("__skip_sequence_replay", true)

        local project_id = args.project_id
        local key = args.key
        local value = args.value

        if not key or key == "" then
            set_last_error("SetProjectSetting: key is required")
            return false
        end

        local ok = database.set_project_setting(project_id, key, value)
        if not ok then
            set_last_error("SetProjectSetting: failed to persist setting")
            return false
        end

        return true
    end

    -- No undoer - this is a non-undoable command

    return {
        executor = command_executors["SetProjectSetting"],
        spec = SPEC,
    }
end

return M
