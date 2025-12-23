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
-- Size: ~44 LOC
-- Volatility: unknown
--
-- @file krono.lua
-- Original intent (unreviewed):
-- Minimal timer helper for profiling hotspots.
-- Uses os.clock so it works anywhere Lua runs in-process.
local M = {}

local python_profiler = nil

local function init_python_profiler()
    if python_profiler ~= nil then
        return python_profiler
    end

    local status, profiler = pcall(function()
        local krono = require("pytools.krono")
        if krono then
            return krono
        end
        return nil
    end)

    if status and profiler then
        python_profiler = profiler
    else
        python_profiler = false
    end

    return python_profiler
end

local function lua_now()
    if os and os.clock then
        return os.clock() * 1000
    end
    return 0
end

function M.now()
    local profiler = python_profiler or init_python_profiler()
    if profiler and profiler.now then
        return profiler.now()
    end
    return lua_now()
end

function M.is_enabled()
    local profiler = python_profiler or init_python_profiler()
    if profiler and profiler.is_enabled then
        return profiler.is_enabled()
    end
    if os and os.getenv then
        return os.getenv("KRONO_TRACE") == "1"
    end
    return false
end

return M
