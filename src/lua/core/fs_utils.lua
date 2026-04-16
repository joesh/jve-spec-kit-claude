--- Shared filesystem helpers — file existence, listing, shell capture.
--
-- Responsibilities:
-- - file_exists / file_mtime / list_dir: read-only filesystem queries
-- - shell_capture: run a shell command, capture stdout via temp file
--   (avoids io.popen EINTR risk under Qt signals/timers)
--
-- Invariants:
-- - shell_capture errors with caller context on command failure
--
-- @file fs_utils.lua
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

--- Run a shell command, capture output to a temp file, read that file.
-- Avoids io.popen pipes — LuaJIT's pipe reads are susceptible to EINTR
-- from Qt signals/timers, and there's no portable way to mask signals
-- in Lua. Writing to a temp file and reading it back sidesteps the issue.
-- @param cmd string: shell command to execute
-- @param context string: caller name for error messages
-- @return string: command stdout (errors on command failure or read failure)
function M.shell_capture(cmd, context)
    local tmp = os.tmpname()
    local exit_code = os.execute(cmd .. " > " .. tmp .. " 2>/dev/null")
    if exit_code ~= 0 then
        os.remove(tmp)
        error(string.format("%s: command failed (exit %s): %s",
            context, tostring(exit_code), cmd), 2)
    end
    local handle, open_err = io.open(tmp, "r")
    if not handle then
        os.remove(tmp)
        error(string.format("%s: failed to open temp file %s: %s",
            context, tmp, tostring(open_err)), 2)
    end
    local data, read_err = handle:read("*all")
    handle:close()
    os.remove(tmp)
    assert(data, string.format("%s: failed to read temp file %s: %s",
        context, tmp, tostring(read_err)))
    return data
end

return M

