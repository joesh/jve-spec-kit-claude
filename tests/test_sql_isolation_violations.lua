--- Test: SQL Isolation Violations
-- Scans non-model Lua files for direct database.get_connection() calls.
-- Only models/ should access the database connection directly.
require('test_env')

local function find_lua_files(dir, results)
    results = results or {}
    local handle = io.popen('find "' .. dir .. '" -name "*.lua" -type f 2>/dev/null')
    if not handle then return results end

    for path in handle:lines() do
        table.insert(results, path)
    end
    handle:close()
    return results
end

local function is_model_file(path)
    return path:match("/models/") ~= nil
end

local function is_test_file(path)
    return path:match("/tests/") ~= nil or path:match("test_") ~= nil
end

local function is_database_module(path)
    return path:match("/core/database%.lua$") ~= nil
end

local function is_core_infrastructure(path)
    -- Core infrastructure files allowed to access database directly:
    -- - command_manager.lua: passes db to sub-modules
    -- - command.lua: Command base class handles persistence
    -- - command_history.lua: undo/redo history persistence
    -- - command_state_manager.lua: state snapshot persistence
    -- - timeline_constraints.lua: calculates valid edit ranges (reads only)
    -- - signals.lua, qt_signals.lua: signal infrastructure (false positive - "connection" means signal)
    local infra_patterns = {
        "/core/command_manager%.lua$",
        "/core/command_history%.lua$",
        "/core/command_state_manager%.lua$",
        "/core/timeline_constraints%.lua$",
        "/core/signals%.lua$",
        "/core/qt_signals%.lua$",
        "/command%.lua$",  -- Command base class
    }
    for _, pattern in ipairs(infra_patterns) do
        if path:match(pattern) then return true end
    end
    return false
end

local function is_importer(path)
    -- Importers handle bulk data import and may need direct DB access
    -- TODO: Consider migrating importers to use models for better isolation
    return path:match("/importers/") ~= nil
end

local function is_whitelisted(path)
    -- Files allowed to call database.get_connection():
    -- 1. models/ - they own SQL
    -- 2. tests/ - test infrastructure
    -- 3. database.lua - the module itself
    -- 4. Core infrastructure - command system backbone
    -- 5. Importers - bulk data import (future: migrate to models)
    return is_model_file(path)
        or is_test_file(path)
        or is_database_module(path)
        or is_core_infrastructure(path)
        or is_importer(path)
end

local function scan_file_for_violations(path)
    local f = io.open(path, "r")
    if not f then return {} end

    local content = f:read("*all")
    f:close()

    local violations = {}
    local line_num = 0

    for line in content:gmatch("[^\n]+") do
        line_num = line_num + 1

        -- Check for database.get_connection() calls
        if line:match("database%.get_connection") or line:match("get_connection%(") then
            -- Skip comments
            if not line:match("^%s*%-%-") then
                table.insert(violations, {
                    line = line_num,
                    code = line:gsub("^%s+", ""):sub(1, 80)
                })
            end
        end
    end

    return violations
end

-- Main test
local src_dir = "../src/lua"

local lua_files = find_lua_files(src_dir)
local all_violations = {}

for _, path in ipairs(lua_files) do
    if not is_whitelisted(path) then
        local violations = scan_file_for_violations(path)
        if #violations > 0 then
            -- Extract relative path for cleaner output
            local rel_path = path:gsub(".*/src/lua/", "")
            all_violations[rel_path] = violations
        end
    end
end

-- Report violations
local violation_count = 0
for path, violations in pairs(all_violations) do
    for _, v in ipairs(violations) do
        violation_count = violation_count + 1
        print(string.format("SQL ISOLATION VIOLATION: %s:%d", path, v.line))
        print(string.format("  %s", v.code))
    end
end

if violation_count > 0 then
    error(string.format("\n%d SQL isolation violation(s) found.\n" ..
        "Only models/ should call database.get_connection() directly.\n" ..
        "Commands and other modules must use model APIs.",
        violation_count))
end

print("✅ test_sql_isolation_violations.lua passed")
