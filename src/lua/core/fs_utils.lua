--- Shared filesystem helpers — file existence, listing, shell capture.
--
-- Responsibilities:
-- - file_exists / file_mtime / list_dir: read-only filesystem queries
-- - shell_capture / try_shell_capture: run a shell command, capture
--   stdout via a temp file. Temp-file indirection avoids io.popen
--   pipe reads, which are EINTR-prone under Qt signal/timer pressure.
--
-- Invariants:
-- - shell_capture errors (with caller context) when the command fails
-- - try_shell_capture returns (ok, data); swallows exit != 0 silently
--   so probes against legitimately-absent paths don't spam logs
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
--- Returns nil if the file doesn't exist (expected case — callers race
--- against FS changes between file_exists and file_mtime).
--- @param path string absolute file path
--- @return number|nil mtime
function M.file_mtime(path)
    if not path or path == "" then return nil end
    local ok, data = M.try_shell_capture(string.format("stat -f %%m %q", path))
    if not ok then return nil end
    local mtime = tonumber((data:gsub("%s+$", "")))
    assert(mtime, string.format(
        "fs_utils.file_mtime: stat succeeded but output non-numeric for %s: %q",
        path, data))
    return mtime
end

--- List filenames in a directory.
--- Returns an array of filename strings (not full paths).
--- Returns empty table if directory doesn't exist or is empty.
--- @param dir string absolute directory path
--- @return table array of filename strings
function M.list_dir(dir)
    if not dir or dir == "" then return {} end
    local ok, listing = M.try_shell_capture(string.format("ls -1 %q", dir))
    if not ok then return {} end
    local result = {}
    for filename in listing:gmatch("[^\n]+") do
        result[#result + 1] = filename
    end
    return result
end

-- Internal: run cmd with stdout redirected to a temp file; read it back.
-- Returns (exit_code, data_or_nil). data is nil when the temp file
-- couldn't be opened (extreme FS failure; real bug).
local function capture_to_tmp(cmd)
    local tmp = os.tmpname()
    local exit_code = os.execute(cmd .. " > " .. tmp .. " 2>/dev/null")
    local handle = io.open(tmp, "r")
    if not handle then
        os.remove(tmp)
        return exit_code, nil
    end
    local data = handle:read("*all")
    handle:close()
    os.remove(tmp)
    return exit_code, data
end

--- Run cmd, return (ok, data). ok=false on non-zero exit. Use for
--- probes where failure is an expected outcome (stat on a missing
--- file, ls on an absent dir) — use shell_capture when failure is a
--- bug worth raising on.
function M.try_shell_capture(cmd)
    local exit_code, data = capture_to_tmp(cmd)
    if exit_code ~= 0 or not data then return false end
    return true, data
end

--- Run cmd; raise on non-zero exit or missing output. Use for
--- commands whose failure indicates a bug.
-- @param cmd string: shell command to execute
-- @param context string: caller name for error messages
-- @return string: command stdout
function M.shell_capture(cmd, context)
    local exit_code, data = capture_to_tmp(cmd)
    if exit_code ~= 0 then
        error(string.format("%s: command failed (exit %s): %s",
            context, tostring(exit_code), cmd), 2)
    end
    assert(data, string.format("%s: failed to capture output (cmd=%s)",
        context, cmd))
    return data
end

return M

