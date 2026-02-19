require("test_env")

local database = require("core.database")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

print("\n=== Empty DB Startup Tests ===")

-- ============================================================
-- Scenario: JVE_PROJECT_PATH points to empty DB (no projects)
-- This reproduces the crash when main.cpp sets JVE_PROJECT_PATH
-- to a .jvp that doesn't exist (sqlite3.open creates it empty)
-- ============================================================

print("\n--- empty DB: get_current_project_id should error ---")
do
    local empty_db_path = "/tmp/jve/test_empty_db_" .. os.time() .. ".jvp"
    os.remove(empty_db_path)
    os.remove(empty_db_path .. "-shm")
    os.remove(empty_db_path .. "-wal")

    -- Open empty DB (schema applied, but no project rows)
    local ok = database.set_path(empty_db_path)
    check("empty DB opens successfully", ok)

    -- get_current_project_id should error on empty DB
    local success, err = pcall(database.get_current_project_id)
    check("get_current_project_id errors on empty DB", not success)
    check("error mentions no projects", tostring(err):match("No projects") ~= nil)

    -- has_projects() should return false on empty DB
    -- THIS IS THE NEW FUNCTION THAT NEEDS TO EXIST FOR SAFE STARTUP CHECKS
    local has_fn = rawget(database, "has_projects")
    check("has_projects() exists", type(has_fn) == "function")
    if type(has_fn) == "function" then
        local has = has_fn()
        check("has_projects() returns false on empty DB", has == false)
    end

    -- Cleanup
    os.remove(empty_db_path)
    os.remove(empty_db_path .. "-shm")
    os.remove(empty_db_path .. "-wal")
end

-- ============================================================
-- Scenario: DB with a real project — has_projects returns true
-- ============================================================

print("\n--- populated DB: has_projects should return true ---")
do
    local pop_db_path = "/tmp/jve/test_populated_db_" .. os.time() .. ".jvp"
    os.remove(pop_db_path)

    database.set_path(pop_db_path)

    -- Create and persist a project so DB is non-empty
    local Project = require("models.project")
    local project = Project.create("Test Project")
    project:save()
    check("project created and saved", project ~= nil)

    local has_fn = rawget(database, "has_projects")
    if type(has_fn) == "function" then
        local has = has_fn()
        check("has_projects() returns true with project", has == true)
    end

    -- get_current_project_id should work
    local success, pid = pcall(database.get_current_project_id)
    if not success then
        print("  get_current_project_id error: " .. tostring(pid))
    end
    check("get_current_project_id succeeds", success)
    if success then
        check("returns project id", pid == project.id)
    end

    -- Cleanup
    os.remove(pop_db_path)
    os.remove(pop_db_path .. "-shm")
    os.remove(pop_db_path .. "-wal")
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Empty DB Startup: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_empty_db_startup.lua passed")
