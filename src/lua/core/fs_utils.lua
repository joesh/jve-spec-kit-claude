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
-- Size: ~13 LOC
-- Volatility: unknown
--
-- @file fs_utils.lua
-- Original intent (unreviewed):
-- fs_utils.lua
-- Shared filesystem helpers (pure Lua, no shelling out).
local M = {}

function M.file_exists(path, mode)
    if not path or path == "" then
        return false
    end
    local file = io.open(path, mode or "rb")
    if file then
        file:close()
        return true
    end
    return false
end

return M

