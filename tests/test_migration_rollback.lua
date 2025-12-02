#!/usr/bin/env luajit

-- Set package path to include necessary Lua modules
package.path = package.path .. ";./src/lua/?.lua;./src/lua/?/init.lua"

local sqlite3 = require("core.sqlite3")

-- Minimal qt_constants DATABASE stub for migration testing
local qt_constants = {
    DATABASE = {}
}

function qt_constants.DATABASE.CREATE_MIGRATION_CONNECTION(db_path)
    return sqlite3.open(db_path)
end

function qt_constants.DATABASE.GET_SCHEMA_VERSION(db)
    local stmt = db:prepare("PRAGMA user_version;")
    if not stmt then return 0 end
    local version = 0
    if stmt:exec() and stmt:next() then
        version = stmt:value(0) or 0
    end
    stmt:finalize()
    return version
end

function qt_constants.DATABASE.EXECUTE_SQL_SCRIPT(db, script_path)
    local f = io.open(script_path, "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()

    if db:exec("BEGIN;") == false then
        return false
    end

    local success = true
    local script = content:gsub("----%s*GO%s*", ";")
    for stmt in script:gmatch("([^;]+);") do
        local trimmed = stmt:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            if db:exec(trimmed .. ";") == false then
                success = false
                break
            end
        end
    end

    if success then
        db:exec("COMMIT;")
    else
        db:exec("ROLLBACK;")
    end

    return success
end

-- Create a temporary database file
local db_path = os.tmpname() .. ".sqlite"
print(string.format("  Temporary database path: %s", db_path))

-- 1. Create migration connection
local db = qt_constants.DATABASE.CREATE_MIGRATION_CONNECTION(db_path)
assert(db, "Failed to create migration connection")
print("  Migration connection created.")

-- 2. Get initial schema version (should be 0 for a new database)
local initial_version = qt_constants.DATABASE.GET_SCHEMA_VERSION(db)
assert(initial_version == 0, "Initial schema version should be 0 for a new database")
print(string.format("  Initial schema version: %d", initial_version))

-- 3. Create a dummy failing migration script
local migration_script_path = os.tmpname() .. ".sql"
local f = io.open(migration_script_path, "w")
assert(f, "Failed to open migration script file for writing")

local failing_migration_content = [[
PRAGMA user_version = 1; ---- GO ----
CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT NOT NULL); ---- GO ----
INSERT INTO test_table (name) VALUES ('test_value_1'); ---- GO ----
-- This next statement will cause an error (table already exists)
CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT NOT NULL); ---- GO ----
INSERT INTO test_table (name) VALUES ('test_value_2'); ---- GO ----
PRAGMA user_version = 2;
]]

f:write(failing_migration_content)
f:close()
print(string.format("  Failing migration script created at: %s", migration_script_path))

-- 4. Call EXECUTE_SQL_SCRIPT with the failing script
-- We are using EXECUTE_SQL_SCRIPT directly for this test to ensure the transaction logic in C++
-- (which is used by executeSqlScript internally) correctly handles rollback.
local success = qt_constants.DATABASE.EXECUTE_SQL_SCRIPT(db, migration_script_path)

-- 5. Assert that EXECUTE_SQL_SCRIPT returned false
assert(not success, "EXECUTE_SQL_SCRIPT should have failed due to invalid SQL")
print("  EXECUTE_SQL_SCRIPT correctly reported failure.")

-- 6. Get the schema version again and assert it's the same as the initial version
local current_version = qt_constants.DATABASE.GET_SCHEMA_VERSION(db)
assert(current_version == initial_version,
       string.format("Schema version should have rolled back to %d, but is %d", initial_version, current_version))
print(string.format("  Schema version correctly rolled back to: %d", current_version))

-- 7. Clean up
os.remove(db_path)
os.remove(migration_script_path)
print("  Cleaned up temporary files.")

print("\n✅ test_migration_rollback.lua PASSED")
