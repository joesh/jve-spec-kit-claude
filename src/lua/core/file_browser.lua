--- file_browser: auto-persisting wrapper around qt_constants.FILE_DIALOG
--
-- Each dialog is identified by a name (e.g. "import_media"). The last-used
-- directory is persisted to ~/.jve/file_browser_paths.json and restored on
-- subsequent opens. Pure persistence + path helpers live in
-- core.file_browser_paths so they can be tested without stubbing the OS
-- file dialog.

local paths = require("core.file_browser_paths")

local M = {}

function M.open_file(name, parent, title, filter, fallback_dir)
    assert(name and name ~= "", "file_browser.open_file: name is required")
    local dir = paths.get_dir(name, fallback_dir)
    local result = qt_constants.FILE_DIALOG.OPEN_FILE(parent, title, filter, dir)
    if result then
        local extracted = paths.extract_dir(result)
        if extracted then paths.persist_dir(name, extracted) end
    end
    return result
end

function M.open_files(name, parent, title, filter, fallback_dir)
    assert(name and name ~= "", "file_browser.open_files: name is required")
    local dir = paths.get_dir(name, fallback_dir)
    local result = qt_constants.FILE_DIALOG.OPEN_FILES(parent, title, filter, dir)
    if result and type(result) == "table" and #result > 0 then
        local extracted = paths.extract_dir(result[1])
        if extracted then paths.persist_dir(name, extracted) end
    end
    return result
end

function M.open_directory(name, parent, title, fallback_dir)
    assert(name and name ~= "", "file_browser.open_directory: name is required")
    local dir = paths.get_dir(name, fallback_dir)
    local result = qt_constants.FILE_DIALOG.OPEN_DIRECTORY(parent, title, dir)
    if result and result ~= "" then paths.persist_dir(name, result) end
    return result
end

function M.save_file(name, parent, title, filter, fallback_dir, default_name)
    assert(name and name ~= "", "file_browser.save_file: name is required")
    local dir = paths.get_dir(name, fallback_dir)
    local initial_path = dir
    if default_name and default_name ~= "" then
        initial_path = (dir ~= "") and (dir .. "/" .. default_name) or default_name
    end
    local result = qt_constants.FILE_DIALOG.SAVE_FILE(parent, title, filter, initial_path)
    if result then
        local extracted = paths.extract_dir(result)
        if extracted then paths.persist_dir(name, extracted) end
    end
    return result
end

function M.get_last_directory(name)
    assert(name and name ~= "", "file_browser.get_last_directory: name is required")
    return paths.get_dir(name)
end

return M
