--- Quit command - clean application shutdown
--
-- @file quit.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {}
}

function M.register(executors, undoers, db)
    local function executor(command)
        local log = require("core.logger").for_area("commands")
        log.event("Quitting application")
        local ok, err = pcall(function()
            local database = require("core.database")
            if database and database.shutdown then
                database.shutdown({ best_effort = true })
            end
        end)
        if not ok then
            log.error("Shutdown error: %s", tostring(err))
        end
        os.exit(0)
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
