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
-- Size: ~62 LOC
-- Volatility: unknown
--
-- @file project_open.lua
local M = {}

local logger = require("core.logger")

-- Check if a file is locked by any process (returns true if locked, false if stale)
local function is_file_locked(path)
    -- Use lsof to check if any process has the file open
    local handle = io.popen('lsof "' .. path .. '" 2>/dev/null | wc -l')
    if not handle then
        return false  -- Can't check, assume not locked
    end
    local result = handle:read("*a")
    handle:close()
    local count = tonumber(result:match("%d+")) or 0
    return count > 1  -- >1 because header line counts as 1
end

function M.open_project_database_or_prompt_cleanup(db_module, qt_constants, project_path, parent_window)
    assert(db_module and db_module.set_path, "project_open: db_module.set_path is required")
    assert(type(project_path) == "string" and project_path ~= "", "project_open: project_path is required")

    -- Check for stale SHM file BEFORE trying to open (sqlite3_open can hang with stale SHM locks)
    -- Note: WAL file contains actual transaction data and must NOT be deleted - SQLite will recover it.
    -- SHM file is just a shared memory index/cache - safe to delete, SQLite recreates it.
    local shm_path = project_path .. "-shm"
    local shm_file = io.open(shm_path, "rb")
    if shm_file then
        shm_file:close()
        -- SHM exists - check if it's locked by another process
        if not is_file_locked(shm_path) then
            -- Stale SHM: no process holds it, safe to delete
            -- This allows SQLite to open and recover the WAL properly
            logger.info("project_open", "Removing stale SHM file (WAL will be recovered): " .. shm_path)
            os.remove(shm_path)
        else
            logger.debug("project_open", "SHM file is actively locked - proceeding with open")
        end
    end

    -- Now try to open the database (SQLite will recover WAL if present)
    local ok = db_module.set_path(project_path)
    if ok then
        return true
    end

    logger.error("project_open", "Failed to open project database: " .. tostring(project_path))
    return false
end

return M

