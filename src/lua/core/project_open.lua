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
local time_utils = require("core.time_utils")

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

    -- Check for stale sidecars BEFORE trying to open (sqlite3_open can hang with stale WAL locks)
    local list_ok, list_result = pcall(db_module.list_wal_sidecars, project_path)
    if list_ok and type(list_result) == "table" then
        local sidecars = list_result
        local has_sidecars = sidecars and (sidecars.wal or sidecars.shm)

        if has_sidecars then
            -- Check if sidecars are actively locked by another process
            local shm_locked = sidecars.shm and is_file_locked(sidecars.shm)
            local wal_locked = sidecars.wal and is_file_locked(sidecars.wal)

            if not shm_locked and not wal_locked then
                -- Sidecars exist but no process holds them - they're stale
                logger.warn("project_open", "Stale WAL/SHM sidecar files detected (not locked by any process)")

                if not qt_constants or not qt_constants.DIALOG or not qt_constants.DIALOG.SHOW_CONFIRM then
                    logger.error("project_open", "Stale sidecars exist but confirm dialog bindings are unavailable")
                    return false
                end

                local existing = {}
                if sidecars.wal then table.insert(existing, sidecars.wal) end
                if sidecars.shm then table.insert(existing, sidecars.shm) end

                local suffix = "stale-" .. time_utils.human_datestamp_for_filename(os.time())
                local accepted = qt_constants.DIALOG.SHOW_CONFIRM({
                    parent = parent_window,
                    title = "Stale Database Lock Files Found",
                    message = "SQLite sidecar files from a previous session were found.",
                    informative_text = "These files are not locked by any process, suggesting they're from a crash or unclean shutdown. Moving them aside allows the database to open safely.\n\nMoving aside preserves the old files in case they contain recent edits.",
                    detail_text = "Project file:\n" .. tostring(project_path) .. "\n\nSidecar files:\n" .. table.concat(existing, "\n") .. "\n\nMove aside suffix:\n" .. suffix,
                    confirm_text = "Move Aside and Continue",
                    cancel_text = "Cancel",
                    icon = "warning",
                    default_button = "confirm",
                })

                if not accepted then
                    return false
                end

                local moved_ok, moved_or_err = pcall(function()
                    return db_module.move_aside_wal_sidecars(project_path, suffix)
                end)
                if not moved_ok then
                    logger.error("project_open", "Failed to move aside sidecars: " .. tostring(moved_or_err))
                    return false
                end
                logger.info("project_open", "Moved aside stale WAL/SHM sidecars")
            else
                logger.debug("project_open", "WAL/SHM sidecars are actively locked - proceeding with open")
            end
        end
    end

    -- Now try to open the database (stale sidecars have been moved if they existed)
    local ok = db_module.set_path(project_path)
    if ok then
        return true
    end

    logger.error("project_open", "Failed to open project database: " .. tostring(project_path))
    return false
end

return M

