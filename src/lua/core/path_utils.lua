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

function M.resolve_repo_root()
    local core_db_path = package.searchpath("core.database", package.path)
    assert(core_db_path, "path_utils requires core.database in package.path for repo root resolution")
    local root = core_db_path:match("(.*)/src/lua/core/database%.lua")
    assert(root, "path_utils failed to derive repo root from core.database path: " .. tostring(core_db_path))
    return root
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
