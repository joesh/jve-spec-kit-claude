--- file_browser: auto-persisting wrapper around qt_constants.FILE_DIALOG
--
-- Each dialog is identified by a name (e.g. "import_media"). The last-used
-- directory is persisted to ~/.jve/file_browser_paths.json and restored on
-- subsequent opens.

local json = require("dkjson")
local logger = require("core.logger")

local M = {}

local PERSISTENCE_DIR = os.getenv("HOME") .. "/.jve"
local PERSISTENCE_PATH = PERSISTENCE_DIR .. "/file_browser_paths.json"

-- In-memory cache; nil = not yet loaded from disk
local paths_cache = nil

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function extract_dir(filepath)
    if not filepath or filepath == "" then return nil end
    -- If path has a file extension, take parent directory
    local dir = filepath:match("^(.+)/[^/]+%.[^/%.]+$")
    if dir then return dir end
    -- Otherwise treat it as a directory path
    return filepath
end

local function ensure_persistence_dir()
    local dir = PERSISTENCE_PATH:match("^(.+)/[^/]+$")
    if dir then
        os.execute(string.format("mkdir -p %q", dir))
    end
end

local function load_paths()
    if paths_cache then return paths_cache end
    local f = io.open(PERSISTENCE_PATH, "r")
    if not f then
        paths_cache = {}
        return paths_cache
    end
    local content = f:read("*a")
    f:close()
    local decoded, _, err = json.decode(content)
    if err or type(decoded) ~= "table" then
        logger.warn("file_browser", "corrupt paths JSON, resetting: " .. tostring(err))
        paths_cache = {}
        return paths_cache
    end
    paths_cache = decoded
    return paths_cache
end

local function save_paths()
    assert(paths_cache, "file_browser.save_paths: paths_cache must be loaded before saving")
    ensure_persistence_dir()
    local encoded = json.encode(paths_cache, { indent = true })
    local f, err = io.open(PERSISTENCE_PATH, "w")
    if not f then
        logger.error("file_browser", "failed to write " .. PERSISTENCE_PATH .. ": " .. tostring(err))
        return
    end
    f:write(encoded)
    f:close()
end

local function get_dir(name, fallback_dir)
    local cached = load_paths()
    local dir = cached[name]
    if dir and dir ~= "" then return dir end
    if fallback_dir and fallback_dir ~= "" then return fallback_dir end
    return ""
end

local function persist_dir(name, dir)
    assert(name, "file_browser.persist_dir: name is required")
    assert(dir, "file_browser.persist_dir: dir is required")
    load_paths()
    paths_cache[name] = dir
    save_paths()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open a single file dialog with auto-persisted directory.
-- @param name       string  unique dialog identifier (e.g. "import_media")
-- @param parent     widget  Qt parent widget
-- @param title      string  dialog title
-- @param filter     string  file filter
-- @param fallback_dir string  optional default when no persisted path
-- @return string|nil  selected file path, or nil if cancelled
function M.open_file(name, parent, title, filter, fallback_dir)
    assert(name and name ~= "", "file_browser.open_file: name is required")
    local dir = get_dir(name, fallback_dir)
    local result = qt_constants.FILE_DIALOG.OPEN_FILE(parent, title, filter, dir)
    if result then
        local extracted = extract_dir(result)
        if extracted then persist_dir(name, extracted) end
    end
    return result
end

--- Open a multi-file dialog with auto-persisted directory.
-- @param name       string  unique dialog identifier
-- @param parent     widget  Qt parent widget
-- @param title      string  dialog title
-- @param filter     string  file filter
-- @param fallback_dir string  optional default when no persisted path
-- @return table|nil  array of file paths, or nil if cancelled
function M.open_files(name, parent, title, filter, fallback_dir)
    assert(name and name ~= "", "file_browser.open_files: name is required")
    local dir = get_dir(name, fallback_dir)
    local result = qt_constants.FILE_DIALOG.OPEN_FILES(parent, title, filter, dir)
    if result and type(result) == "table" and #result > 0 then
        local extracted = extract_dir(result[1])
        if extracted then persist_dir(name, extracted) end
    end
    return result
end

--- Open a directory dialog with auto-persisted directory.
-- @param name       string  unique dialog identifier
-- @param parent     widget  Qt parent widget
-- @param title      string  dialog title
-- @param fallback_dir string  optional default when no persisted path
-- @return string|nil  selected directory path, or nil if cancelled
function M.open_directory(name, parent, title, fallback_dir)
    assert(name and name ~= "", "file_browser.open_directory: name is required")
    local dir = get_dir(name, fallback_dir)
    local result = qt_constants.FILE_DIALOG.OPEN_DIRECTORY(parent, title, dir)
    if result and result ~= "" then
        persist_dir(name, result)
    end
    return result
end

--- Open a save file dialog with auto-persisted directory.
-- @param name         string  unique dialog identifier (e.g. "save_project")
-- @param parent       widget  Qt parent widget
-- @param title        string  dialog title
-- @param filter       string  file filter (e.g. "JVE Project (*.jvp)")
-- @param fallback_dir string  optional default when no persisted path
-- @param default_name string  optional default filename (e.g. "Untitled.jvp")
-- @return string|nil  selected file path, or nil if cancelled
function M.save_file(name, parent, title, filter, fallback_dir, default_name)
    assert(name and name ~= "", "file_browser.save_file: name is required")
    local dir = get_dir(name, fallback_dir)
    -- Combine directory with default filename if provided
    local initial_path = dir
    if default_name and default_name ~= "" then
        if dir ~= "" then
            initial_path = dir .. "/" .. default_name
        else
            initial_path = default_name
        end
    end
    local result = qt_constants.FILE_DIALOG.SAVE_FILE(parent, title, filter, initial_path)
    if result then
        local extracted = extract_dir(result)
        if extracted then persist_dir(name, extracted) end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Test helpers (prefixed with _ to signal internal use)
-- ---------------------------------------------------------------------------

function M._set_persistence_path(path)
    PERSISTENCE_PATH = path
    paths_cache = nil  -- force reload
end

M._extract_dir = extract_dir

return M
