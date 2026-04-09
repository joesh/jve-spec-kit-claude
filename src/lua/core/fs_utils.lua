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

--- Get file modification time (seconds since epoch).
--- Returns nil if file doesn't exist or stat fails.
--- @param path string absolute file path
--- @return number|nil mtime
function M.file_mtime(path)
    if not path or path == "" then return nil end
    local handle = io.popen(string.format("stat -f '%%m' %q 2>/dev/null", path))
    if not handle then return nil end
    local mtime_str = handle:read("*l")
    handle:close()
    return tonumber(mtime_str)
end

--- List filenames in a directory.
--- Returns an array of filename strings (not full paths).
--- Returns empty table if directory doesn't exist or is empty.
--- @param dir string absolute directory path
--- @return table array of filename strings
function M.list_dir(dir)
    if not dir or dir == "" then return {} end
    local handle = io.popen(string.format("ls -1 %q 2>/dev/null", dir))
    if not handle then return {} end
    local listing = handle:read("*a")
    handle:close()
    local result = {}
    for filename in listing:gmatch("[^\n]+") do
        result[#result + 1] = filename
    end
    return result
end

return M

