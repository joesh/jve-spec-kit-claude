--- recent_projects: MRU list persisted at ~/.jve/recent_projects.json
--
-- Responsibilities:
-- - Load/save recent project list (max 10, most-recent-first)
-- - Filter out missing files on load
-- - Add/remove entries
--
-- Non-goals:
-- - Watching filesystem for changes
-- - Project metadata beyond name/path/last_opened
--
-- Invariants:
-- - load() always filters missing files (stale entries removed automatically)
-- - add() moves existing path to top (deduplicates)
-- - List never exceeds MAX_RECENT entries
--
-- Size: ~60 LOC
-- Volatility: low
--
-- @file recent_projects.lua
local M = {}
local json = require("dkjson")
local logger = require("core.logger")

local MAX_RECENT = 10

local function persistence_path()
    local home = os.getenv("HOME")
    assert(home, "recent_projects: HOME not set")
    return home .. "/.jve/recent_projects.json"
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

--- Load recent projects, filtering out entries whose .jvp no longer exists.
-- @return array of {name, path, last_opened}
function M.load()
    local path = persistence_path()
    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()

    local decoded, _, err = json.decode(content)
    if err or type(decoded) ~= "table" then
        logger.warn("recent_projects", "corrupt JSON, resetting: " .. tostring(err))
        return {}
    end

    -- Filter out missing files
    local result = {}
    for _, entry in ipairs(decoded) do
        if type(entry) == "table" and entry.path and file_exists(entry.path) then
            result[#result + 1] = entry
        end
    end
    return result
end

--- Add (or move to top) a project entry. Saves immediately.
-- @param name string: project display name
-- @param path string: absolute path to .jvp
function M.add(name, path)
    assert(name and name ~= "", "recent_projects.add: name required")
    assert(path and path ~= "", "recent_projects.add: path required")

    local entries = M.load()

    -- Remove existing entry with same path (will re-add at top)
    local filtered = {}
    for _, entry in ipairs(entries) do
        if entry.path ~= path then
            filtered[#filtered + 1] = entry
        end
    end

    -- Insert at top
    table.insert(filtered, 1, {
        name = name,
        path = path,
        last_opened = os.time(),
    })

    -- Trim to max
    while #filtered > MAX_RECENT do
        filtered[#filtered] = nil
    end

    -- Save
    local persistence = persistence_path()
    local dir = persistence:match("^(.+)/[^/]+$")
    if dir then
        os.execute(string.format("mkdir -p %q", dir))
    end
    local encoded = json.encode(filtered, { indent = true })
    local f, err = io.open(persistence, "w")
    if not f then
        logger.error("recent_projects", "failed to write: " .. tostring(err))
        return
    end
    f:write(encoded)
    f:close()
end

--- Remove a project entry by path. Saves immediately.
-- @param path string: absolute path to .jvp
function M.remove(path)
    assert(path and path ~= "", "recent_projects.remove: path required")

    local entries = M.load()
    local filtered = {}
    for _, entry in ipairs(entries) do
        if entry.path ~= path then
            filtered[#filtered + 1] = entry
        end
    end

    local persistence = persistence_path()
    local encoded = json.encode(filtered, { indent = true })
    local f, err = io.open(persistence, "w")
    if not f then
        logger.error("recent_projects", "failed to write: " .. tostring(err))
        return
    end
    f:write(encoded)
    f:close()
end

return M
