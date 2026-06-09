local M = {}

local log = require("core.logger").for_area("media")

-- ============================================================================
-- Pidlock-based SHM staleness check.
--
-- Why not pgrep / lsof / fuser:
--   macOS Hardened-Runtime / adhoc-codesigned .app processes are invisible
--   to other process' KERN_PROCARGS2 / lsof fd-table queries (verified
--   2026-06-03: from inside a .app, `lsof <shm>`, `pgrep -f jve`, and
--   `fuser <shm>` all return empty even when another JVE is actively
--   holding the file). The kernel hides .app process introspection from
--   peer .apps. Process-name detection is fundamentally unreliable here.
--
-- What we do instead:
--   On every successful project open, JVE writes its own PID to
--   `<project>.jvp-pidlock`. On next open, if SHM exists we read the
--   pidlock and `kill -0` it:
--     • pidlock missing / PID dead  →  prior JVE crashed without cleanup.
--       SHM may be stale; safe to delete (SQLite will recover the WAL).
--     • PID alive                   →  another JVE has this project open.
--       Leave SHM in place; set_path will fail and the user gets a clear
--       "already open" indication.
--
--   No process-introspection needed — kill(pid, 0) works regardless of
--   the .app introspection wall because the kernel grants `joe` the right
--   to signal-test his own processes.
--
--   The pidlock is per-project, which is the correct scope: the question
--   we actually care about is "did the JVE that owned THIS project's SHM
--   exit cleanly?", not "is JVE running anywhere".
-- ============================================================================

local function pidlock_path(project_path) return project_path .. "-jve-pidlock" end

local function our_pid()
    assert(type(qt_get_pid) == "function",
        "project_open.our_pid: qt_get_pid binding missing")
    local pid = qt_get_pid()
    assert(type(pid) == "number" and pid > 0, string.format(
        "project_open.our_pid: qt_get_pid returned %s", tostring(pid)))
    return pid
end

local function pid_is_alive(pid)
    assert(type(pid) == "number" and pid > 0,
        "project_open.pid_is_alive: pid must be a positive number")
    -- /bin/kill -0 returns 0 if the process exists and we can signal it.
    -- LuaJIT's os.execute returns exit_code directly (not the
    -- (ok, "exit", code) tuple of stock 5.2+); 0 means alive.
    local rc = os.execute("/bin/kill -0 " .. tostring(pid) .. " 2>/dev/null")
    return rc == 0 or rc == true
end

local function read_pidlock(project_path)
    local f = io.open(pidlock_path(project_path), "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    if not s then return nil end
    return tonumber((s:gsub("%s+", "")))
end

-- Path of the project whose pidlock THIS process currently holds, or nil
-- when none. Tracked so project-switch and shutdown can release it without
-- the caller having to remember what was open.
local current_locked_path = nil

local function write_pidlock(project_path)
    local path = pidlock_path(project_path)
    local f, err = io.open(path, "w")
    assert(f, string.format(
        "project_open.write_pidlock: open %q failed: %s",
        path, tostring(err)))
    f:write(tostring(our_pid()))
    f:close()
    current_locked_path = project_path
end

--- Release the pidlock for the currently-held project, if any.
-- Safe to call multiple times; no-op when nothing is held.
function M.release_current_pidlock()
    if not current_locked_path then return end
    local path = pidlock_path(current_locked_path)
    -- Only remove if it still points at us — defends against the rare case
    -- where another process has already claimed this project (its pidlock
    -- now contains their PID, not ours) and we'd otherwise yank their lock.
    local prior = read_pidlock(current_locked_path)
    if prior == our_pid() then
        local ok, err = os.remove(path)
        if not ok then
            log.warn("release_current_pidlock: os.remove(%q) failed: %s",
                path, tostring(err))
        end
    end
    current_locked_path = nil
end

-- Returns true iff a live, non-self process owns this project's pidlock.
-- Self-PID match is impossible during a fresh open (we haven't written
-- our lock yet) but defended against anyway — a leftover lock from a
-- prior session of THIS process is by definition stale, not held.
local function another_jve_owns_project(project_path)
    local prior = read_pidlock(project_path)
    if not prior then return false end
    if prior == our_pid() then return false end
    return pid_is_alive(prior)
end

function M.open_project_database_or_prompt_cleanup(db_module, qt_constants, project_path, parent_window)
    assert(db_module and db_module.set_path, "project_open: db_module.set_path is required")
    assert(type(project_path) == "string" and project_path ~= "", "project_open: project_path is required")

    local outgoing_path = current_locked_path

    -- Check for stale SHM BEFORE sqlite3_open (which can hang on stale
    -- WAL locks during ftruncate). WAL itself stays — SQLite recovers
    -- transactions from it; only SHM (shared-mem index) is touched here.
    local shm_path = project_path .. "-shm"
    local shm_file = io.open(shm_path, "rb")
    if shm_file then
        shm_file:close()
        if another_jve_owns_project(project_path) then
            log.event("Another jve process owns %s (pidlock alive) — leaving SHM in place",
                project_path)
        else
            log.event("Removing stale SHM file (WAL will be recovered): %s", shm_path)
            os.remove(shm_path)
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

    -- Record that THIS JVE process now owns this project's SHM so the
    -- next open can tell stale-from-crash apart from concurrent-open.
    write_pidlock(project_path)

    -- Successfully claimed the new project: NOW we can release the old one.
    -- (Rule 2.32: No silent drop of lock-held coverage).
    if outgoing_path and outgoing_path ~= project_path then
        local path = pidlock_path(outgoing_path)
        local prior = read_pidlock(outgoing_path)
        if prior == our_pid() then
            os.remove(path)
        end
    end
    return true
end

return M

