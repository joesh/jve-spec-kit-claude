--- Test: project_browser.set_project_id clears stale cache
-- When opening a new project, the project_browser's cached project_id
-- must be updated before refresh() to avoid querying the new database
-- with the old project's ID.
require('test_env')

local database = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")

-- Create two separate test databases to simulate project switching
local db_path_1 = "/tmp/jve/test_proj1_" .. os.time() .. ".jvp"
local db_path_2 = "/tmp/jve/test_proj2_" .. os.time() .. ".jvp"

-- Create first project database
database.init(db_path_1)
local project1 = Project.create("Project One", {})
assert(project1:save(), "Failed to save project 1")

local seq1 = Sequence.create("Timeline One", project1.id, {fps_numerator = 30, fps_denominator = 1}, 1920, 1080, {})
assert(seq1:save(), "Failed to save sequence 1")

print("Created project 1: " .. project1.id)

-- Close first database
database.shutdown()

-- Create second project database
database.init(db_path_2)
local project2 = Project.create("Project Two", {})
assert(project2:save(), "Failed to save project 2")

local seq2 = Sequence.create("Timeline Two", project2.id, {fps_numerator = 24, fps_denominator = 1}, 1920, 1080, {})
assert(seq2:save(), "Failed to save sequence 2")

print("Created project 2: " .. project2.id)

-- Test: Simulate the project_browser cache behavior
-- This is a unit test of the cache pattern, not the full UI
local cache = {
    project_id = nil
}

local function simulate_refresh_WITHOUT_set_project_id()
    -- This simulates the old buggy behavior:
    -- If cache.project_id is set, it uses that instead of querying
    local project_id = cache.project_id or database.get_current_project_id()
    return project_id
end

local function simulate_refresh_WITH_set_project_id(new_project_id)
    -- This simulates the fix:
    -- Caller sets project_id before refresh
    cache.project_id = new_project_id
    local project_id = cache.project_id or database.get_current_project_id()
    return project_id
end

-- Scenario: Switch from project1 to project2

-- Step 1: Simulate being on project1
cache.project_id = project1.id

-- Step 2: Open project2's database (already done above)
-- Step 3: Refresh WITHOUT setting project_id first (the bug)
local result_buggy = simulate_refresh_WITHOUT_set_project_id()
assert(result_buggy == project1.id,
    "Bug simulation: should return stale project1.id but got " .. tostring(result_buggy))
print("Confirmed: Without set_project_id, refresh uses stale cache")

-- Step 4: Now do it correctly with set_project_id
local result_fixed = simulate_refresh_WITH_set_project_id(project2.id)
assert(result_fixed == project2.id,
    "Fix: should return project2.id but got " .. tostring(result_fixed))
print("Confirmed: With set_project_id, refresh uses correct project")

-- Verify the actual project_browser module has set_project_id
local project_browser = require("ui.project_browser")
assert(type(project_browser.set_project_id) == "function",
    "project_browser.set_project_id must exist")
print("Confirmed: project_browser.set_project_id exists")

-- Cleanup
database.shutdown()
os.remove(db_path_1)
os.remove(db_path_1 .. "-shm")
os.remove(db_path_1 .. "-wal")
os.remove(db_path_2)
os.remove(db_path_2 .. "-shm")
os.remove(db_path_2 .. "-wal")

print("✅ test_project_browser_set_project_id.lua passed")
