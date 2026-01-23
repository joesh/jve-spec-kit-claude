#!/usr/bin/env luajit

-- Test CreateProject command
-- Verifies: project creation, name requirement

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/jve/test_create_project.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

-- Need a minimal project to initialize command_manager
db:exec([[
    INSERT INTO projects (id, name) VALUES ('init_project', 'Init Project');
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, width, height)
    VALUES ('init_sequence', 'init_project', 'Init Sequence', 30, 1, 1920, 1080);
]])

command_manager.init('init_sequence', 'init_project')

print("=== CreateProject Tests ===")

-- Test 1: CreateProject with name creates a new project
print("Test 1: CreateProject creates new project with name")
local result = command_manager.execute("CreateProject", {
    project_id = "new_project_1",
    name = "Test Project One"
})
assert(result.success, "CreateProject should succeed: " .. tostring(result.error_message))

-- Verify project was created in database
local stmt = db:prepare("SELECT name FROM projects WHERE id = 'new_project_1'")
assert(stmt:exec() and stmt:next(), "Project should exist in database")
local created_name = stmt:value(0)
stmt:finalize()
assert(created_name == "Test Project One",
    string.format("Project name should be 'Test Project One', got '%s'", tostring(created_name)))

print("✅ CreateProject tests passed")
