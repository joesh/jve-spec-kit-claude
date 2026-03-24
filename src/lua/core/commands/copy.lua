--- Copy — copies selected clips/browser items to clipboard.
-- Focus-aware: routes to timeline or project browser via clipboard_actions.
-- Non-undoable wrapper — clipboard is in-memory only, no DB mutation.
local M = {}

local clipboard_actions = require("core.clipboard_actions")
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
    }
}

function M.register(command_executors)
    command_executors["Copy"] = function(_command)
        local ok, err = clipboard_actions.copy()
        if not ok then
            log.warn("Copy: %s", err or "nothing to copy")
            return false
        end
        return true
    end

    return {
        executor = command_executors["Copy"],
        spec = SPEC,
    }
end

return M
