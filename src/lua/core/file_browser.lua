--- file_browser: auto-persisting wrapper around qt_constants.FILE_DIALOG
--
-- Each dialog is identified by a name (e.g. "import_media"). The last-used
-- directory is persisted to ~/.jve/file_browser_paths.json and restored on
-- subsequent opens. Pure persistence + path helpers live in
-- core.file_browser_paths so they can be tested without stubbing the OS
-- file dialog.

local paths = require("core.file_browser_paths")

local M = {}

local function require_name(fn_name, name)
    assert(name and name ~= "",
        "file_browser." .. fn_name .. ": name is required")
end

-- Persist the parent directory of `file_path` under `name`. No-op if the
-- dialog returned nil (user cancelled) or extract_dir can't derive a dir.
local function persist_parent_dir(name, file_path)
    if not file_path then return end
    local extracted = paths.extract_dir(file_path)
    if extracted then paths.persist_dir(name, extracted) end
end

function M.open_file(name, parent, title, filter, fallback_dir)
    require_name("open_file", name)
    local result = qt_constants.FILE_DIALOG.OPEN_FILE(
        parent, title, filter, paths.get_dir(name, fallback_dir))
    persist_parent_dir(name, result)
    return result
end

function M.open_files(name, parent, title, filter, fallback_dir)
    require_name("open_files", name)
    local result = qt_constants.FILE_DIALOG.OPEN_FILES(
        parent, title, filter, paths.get_dir(name, fallback_dir))
    if type(result) == "table" and #result > 0 then
        persist_parent_dir(name, result[1])
    end
    return result
end

function M.open_directory(name, parent, title, fallback_dir)
    require_name("open_directory", name)
    local result = qt_constants.FILE_DIALOG.OPEN_DIRECTORY(
        parent, title, paths.get_dir(name, fallback_dir))
    -- Directory dialogs return the dir itself, not a file path inside it.
    if result and result ~= "" then paths.persist_dir(name, result) end
    return result
end

function M.save_file(name, parent, title, filter, fallback_dir, default_name)
    require_name("save_file", name)
    local dir = paths.get_dir(name, fallback_dir)
    local initial_path = dir
    if default_name and default_name ~= "" then
        initial_path = (dir ~= "") and (dir .. "/" .. default_name) or default_name
    end
    local result = qt_constants.FILE_DIALOG.SAVE_FILE(
        parent, title, filter, initial_path)
    persist_parent_dir(name, result)
    return result
end

function M.get_last_directory(name)
    require_name("get_last_directory", name)
    return paths.get_dir(name)
end

return M
