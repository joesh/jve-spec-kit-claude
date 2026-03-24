--- Paste — pastes clipboard contents at the playhead.
-- Focus-aware: routes to timeline or project browser via clipboard_actions.
-- Non-undoable wrapper — delegates to Overwrite which handles undo directly.
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
    command_executors["Paste"] = function(_command)
        local ok, err = clipboard_actions.paste()
        if not ok then
            log.warn("Paste: %s", err or "nothing to paste")
            return false
        end
        return true
    end

    return {
        executor = command_executors["Paste"],
        spec = SPEC,
    }
end

return M
