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
-- Size: ~27 LOC
-- Volatility: unknown
--
-- @file table_utils.lua
-- Original intent (unreviewed):
-- table_utils.lua
-- Shared table utilities (copying, transforms, etc.)
local M = {}

function M.shallow_copy(tbl)
    if type(tbl) ~= "table" then
        return tbl
    end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = v
    end
    return out
end

function M.deep_copy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local result = {}
    seen[value] = result
    for k, v in pairs(value) do
        result[M.deep_copy(k, seen)] = M.deep_copy(v, seen)
    end
    return result
end

return M

