--- file_browser_paths: pure persistence + path helpers for file_browser.
--
-- Holds the JSON-backed map of last-used directories per named dialog,
-- plus the parent-dir extraction rule used to derive a "next-time" hint
-- from a selected file path. No Qt, no dialogs — pure I/O + string.
--
-- Split out from file_browser.lua so the persistence layer can be tested
-- without stubbing qt_constants.FILE_DIALOG (the OS file dialog is an
-- interactive system boundary that hangs --test mode).

local json = require("dkjson")
local log = require("core.logger").for_area("media")

local M = {}

local DEFAULT_PATH = os.getenv("HOME") .. "/.jve/file_browser_paths.json"
local persistence_path = DEFAULT_PATH

-- nil = not yet loaded from disk. Reset on set_persistence_path so tests
-- can swap files between scenarios.
local paths_cache = nil

function M.extract_dir(filepath)
    if not filepath or filepath == "" then return nil end
    -- File with extension → parent dir; bare path → treat as dir.
    local dir = filepath:match("^(.+)/[^/]+%.[^/%.]+$")
    if dir then return dir end
    return filepath
end

local function ensure_persistence_dir()
    local dir = persistence_path:match("^(.+)/[^/]+$")
    if dir then
        local ok, err = qt_fs_mkdir_p(dir)
        assert(ok, "file_browser_paths: mkdir " .. dir .. " failed: " .. tostring(err))
    end
end

local function load_paths()
    if paths_cache then return paths_cache end
    local f = io.open(persistence_path, "r")
    if not f then paths_cache = {}; return paths_cache end
    local content = f:read("*a")
    f:close()
    local decoded, _, err = json.decode(content)
    if err or type(decoded) ~= "table" then
        log.warn("corrupt paths JSON, resetting: %s", tostring(err))
        paths_cache = {}
        return paths_cache
    end
    paths_cache = decoded
    return paths_cache
end

local function save_paths()
    assert(paths_cache,
        "file_browser_paths.save: paths_cache must be loaded before saving")
    ensure_persistence_dir()
    local encoded = json.encode(paths_cache, { indent = true })
    local f, err = io.open(persistence_path, "w")
    if not f then
        log.error("failed to write %s: %s", persistence_path, tostring(err))
        return
    end
    f:write(encoded)
    f:close()
end

function M.get_dir(name, fallback_dir)
    local cached = load_paths()
    local dir = cached[name]
    if dir and dir ~= "" then return dir end
    if fallback_dir and fallback_dir ~= "" then return fallback_dir end
    return ""
end

function M.persist_dir(name, dir)
    assert(name, "file_browser_paths.persist_dir: name is required")
    assert(dir, "file_browser_paths.persist_dir: dir is required")
    load_paths()
    paths_cache[name] = dir
    save_paths()
end

--- Test seam: redirect persistence to a fresh path and drop the cache.
function M.set_persistence_path(path)
    persistence_path = path
    paths_cache = nil
end

--- Test seam: drop in-memory cache so the next read hits disk.
function M.reset_cache()
    paths_cache = nil
end

return M
