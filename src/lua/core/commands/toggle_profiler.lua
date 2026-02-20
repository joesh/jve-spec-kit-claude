--- ToggleProfiler command - start/stop LuaJIT sampling profiler
--
-- Bound to Shift+F12. Writes report to /tmp/jve/profile_report.txt.
--
-- @file toggle_profiler.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {}
}

function M.register(executors, undoers, db)
    local function executor(command)
        local profiler = require("core.lua_profiler")
        profiler.toggle()
        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
