#!/usr/bin/env luajit

-- Test SetupProject command
-- Verifies: settings update, previous settings storage

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/jve/test_setup_project.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at, settings)
    VALUES ('test_project', 'Test Project', 0, 0, '{"resolution": "1080p"}');
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, width, height)
    VALUES ('test_sequence', 'test_project', 'Test Sequence', 30, 1, 1920, 1080);
]])

command_manager.init('test_sequence', 'test_project')

print("=== SetupProject Tests ===")

-- Test 1: SetupProject updates settings
print("Test 1: SetupProject updates settings")
local result = command_manager.execute("SetupProject", {
    project_id = "test_project",
    settings = {resolution = "4K", frame_rate = 60}
})
assert(result.success, "SetupProject should succeed: " .. tostring(result.error_message))

-- Verify settings were updated
local stmt = db:prepare("SELECT settings FROM projects WHERE id = 'test_project'")
assert(stmt:exec() and stmt:next(), "Project should exist")
local settings_json = stmt:value(0)
stmt:finalize()
assert(settings_json:find("4K"), "Settings should contain '4K': " .. tostring(settings_json))

-- Test 2: SetupProject fails for nonexistent project
print("Test 2: SetupProject fails for nonexistent project")
result = command_manager.execute("SetupProject", {
    project_id = "nonexistent",
    settings = {test = "value"}
})
assert(not result.success, "SetupProject should fail for nonexistent project")

print("✅ SetupProject tests passed")
