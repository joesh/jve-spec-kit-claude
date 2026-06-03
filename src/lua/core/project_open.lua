local M = {}

local log = require("core.logger").for_area("media")

-- Is the existing SHM file owned by a live JVE process other than us?
--
-- True semantics: "is there another jve running that might be holding
-- this SHM?" If yes, SHM is real — leave it. If no (we are the only
-- jve), SHM is stale from a prior crash — safe to delete so SQLite
-- can recover the WAL.
--
-- Replaced an earlier `lsof "<path>" | wc -l` shellout. lsof's output
-- is large/variable and at least once (2026-06-03 TSO) returned a nil
-- read from io.popen, asserting the OpenProject path. pgrep output is
-- one PID per line — tiny, deterministic, matches the invariant
-- documented in CLAUDE.md ("pgrep -x jve || rm -f ...-shm").
local function another_jve_is_running()
    local handle = assert(io.popen("pgrep -x jve"),
        "project_open.another_jve_is_running: io.popen(pgrep) failed")
    local out = handle:read("*a")
    handle:close()
    assert(out ~= nil,
        "project_open.another_jve_is_running: pgrep pipe read returned nil")
    -- Count non-empty lines. Inside a running JVE process pgrep finds
    -- at least our own pid, so >= 2 means a second jve is alive.
    local n = 0
    for _ in out:gmatch("[^\n]+") do n = n + 1 end
    assert(n >= 1, string.format(
        "project_open.another_jve_is_running: pgrep -x jve returned 0 "
        .. "matches but we are running — output=%q", out))
    return n >= 2
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
        -- SHM exists - if we are the only jve process, it's stale
        if not another_jve_is_running() then
            log.event("Removing stale SHM file (WAL will be recovered): %s", shm_path)
            os.remove(shm_path)
        else
            log.event("Another jve process is running — leaving SHM in place: %s", shm_path)
        end
    end

    -- Now try to open the database (SQLite will recover WAL if present)
    -- set_path checks schema_version BEFORE applying schema — incompatible
    -- versions error() with a user-facing message (caught by layout.lua pcall).
    local ok = db_module.set_path(project_path)
    if not ok then
        log.error("Failed to open project database: %s", tostring(project_path))
        return false
    end

    return true
end

return M

