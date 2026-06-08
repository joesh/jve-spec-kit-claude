local M = {}

local function is_absolute_path(path)
    if not path or path == "" then
        return false
    end
    if path:sub(1, 1) == "/" then
        return true
    end
    if path:match("^%a:[/\\]") then
        return true
    end
    return false
end

local function get_logger()
    local ok, logger = pcall(require, "core.logger")
    if ok then return logger.for_area("database") end
    return { detail = function() end, event = function() end, warn = function() end, error = function() end }
end

function M.resolve_repo_root()
    local log = get_logger()
    local override = os.getenv("JVE_REPO_ROOT")
    if override and override ~= "" then
        return override:gsub("/$", "")
    end

    local core_db_path = package.searchpath("core.database", package.path)
    assert(core_db_path, "path_utils requires core.database in package.path for repo root resolution")

    -- Derive the Lua root by stripping the module path tail.
    -- (e.g. ".../src/lua/core/database.lua" -> ".../src/lua")
    local lua_root = core_db_path:match("(.*)/core/database%.lua")
    if not lua_root then
        error("path_utils failed to derive Lua root from core.database path: " .. tostring(core_db_path))
    end
    log.detail("path_utils: derived lua_root=%s", lua_root)

    -- If we're in a repo, 'src/lua' is the root of our module tree.
    -- The repo root is the parent of 'src'.
    local repo_root_candidate = lua_root:match("(.*)/src/lua$") or lua_root
    log.detail("path_utils: repo_root_candidate=%s", repo_root_candidate)

    -- Walk up from the repo_root_candidate until we find the repository root.
    -- Repository root is identified by the presence of 'tools/resolve-helper/helper.py'.
    -- If we never find it (e.g. production build where tools/ isn't bundled),
    -- we fall back to the repo_root_candidate.
    local root = repo_root_candidate
    for _ = 1, 6 do
        local test_path = root .. "/tools/resolve-helper/helper.py"
        local f = io.open(test_path, "r")
        if f then
            f:close()
            return root
        end
        local parent = root:match("(.*)/[^/]+$")
        if not parent or parent == "" then break end
        root = parent
    end

    error("path_utils failed to resolve repo root (could not find tools/resolve-helper/helper.py starting from " .. repo_root_candidate .. ")")
end

function M.resolve_repo_path(path)
    if not path or path == "" then
        return path
    end
    if is_absolute_path(path) then
        return path
    end
    return M.resolve_repo_root() .. "/" .. path:gsub("^/+", "")
end

return M
