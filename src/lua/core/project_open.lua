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

function M.open_project_database_or_prompt_cleanup(db_module, qt_constants, project_path, parent_window)
    assert(db_module and db_module.set_path, "project_open: db_module.set_path is required")
    assert(type(project_path) == "string" and project_path ~= "", "project_open: project_path is required")

    local ok = db_module.set_path(project_path)
    if ok then
        return true
    end

    local list_ok, list_result = pcall(db_module.list_wal_sidecars, project_path)
    if not list_ok then
        logger.error("project_open", "Failed to check for WAL/SHM sidecars: " .. tostring(list_result))
        return false
    end
    if type(list_result) ~= "table" then
        logger.error("project_open", "database.list_wal_sidecars returned unexpected type: " .. type(list_result))
        return false
    end
    local sidecars = list_result

    local has_sidecars = sidecars and (sidecars.wal or sidecars.shm)
    if not has_sidecars then
        return false
    end

    if not qt_constants or not qt_constants.DIALOG or not qt_constants.DIALOG.SHOW_CONFIRM then
        logger.error("project_open", "Project open failed and WAL/SHM sidecars exist, but confirm dialog bindings are unavailable")
        return false
    end

    local existing = {}
    if sidecars.wal then table.insert(existing, sidecars.wal) end
    if sidecars.shm then table.insert(existing, sidecars.shm) end

    local suffix = "stale-" .. time_utils.human_datestamp_for_filename(os.time())
    local accepted = qt_constants.DIALOG.SHOW_CONFIRM({
        parent = parent_window,
        title = "Project Open Failed",
        message = "This project database failed to open, but SQLite sidecar files were found.",
        informative_text = "If you replaced the project file with another version, these sidecar files may belong to the previous database. You can move them aside and retry opening.\n\nMoving aside is safer than deleting: it preserves the old files in case they contain recent edits.",
        detail_text = "Project file:\n" .. tostring(project_path) .. "\n\nSidecar files:\n" .. table.concat(existing, "\n") .. "\n\nMove aside suffix:\n" .. suffix,
        confirm_text = "Move Aside and Retry",
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

    local retry_ok = db_module.set_path(project_path)
    if not retry_ok then
        logger.error("project_open", "Retry failed after moving aside WAL/SHM sidecars")
        return false
    end

    logger.info("project_open", "Opened project database after moving aside WAL/SHM sidecars")
    return true
end

return M

