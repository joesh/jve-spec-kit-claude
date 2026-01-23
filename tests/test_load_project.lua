#!/usr/bin/env luajit

-- Test LoadProject command - comprehensive coverage
-- Tests: basic load, nonexistent project, undo behavior (none expected)

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local asserts = require('core.asserts')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== LoadProject Command Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_load_project.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert test data
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at, settings)
    VALUES ('project_1', 'Test Project One', %d, %d, '{"key":"value"}');
]], now, now))
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at, settings)
    VALUES ('project_2', 'Test Project Two', %d, %d, '{}');
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence_1', 'project_1', 'Test Sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))

command_manager.init('sequence_1', 'project_1')

-- Helper: execute command with proper event wrapping
local function execute_command(name, params)
    command_manager.begin_command_event("script")
    local result = command_manager.execute(name, params)
    command_manager.end_command_event()
    return result
end

-- =============================================================================
-- TEST 1: Basic LoadProject with existing project
-- =============================================================================
print("Test 1: LoadProject loads existing project successfully")
local result = execute_command("LoadProject", {
    project_id = "project_1"
})
assert(result.success, "LoadProject should succeed for existing project: " .. tostring(result.error_message))

-- =============================================================================
-- TEST 2: LoadProject fails for nonexistent project
-- =============================================================================
print("Test 2: LoadProject fails for nonexistent project")
result = execute_command("LoadProject", {
    project_id = "nonexistent_project"
})
assert(not result.success, "LoadProject should fail for nonexistent project")

-- =============================================================================
-- TEST 3: LoadProject fails when project_id is missing
-- =============================================================================
print("Test 3: LoadProject fails when project_id is missing")
-- Disable asserts for error case testing (schema validation asserts on missing required params)
asserts._set_enabled_for_tests(false)
result = execute_command("LoadProject", {})
asserts._set_enabled_for_tests(true)
assert(not result.success, "LoadProject should fail when project_id is missing")

-- =============================================================================
-- TEST 4: LoadProject with empty project_id fails
-- =============================================================================
print("Test 4: LoadProject fails with empty project_id")
asserts._set_enabled_for_tests(false)
result = execute_command("LoadProject", {
    project_id = ""
})
asserts._set_enabled_for_tests(true)
assert(not result.success, "LoadProject should fail with empty project_id")

-- =============================================================================
-- TEST 5: LoadProject can load different projects in sequence
-- =============================================================================
print("Test 5: LoadProject can load multiple projects")
result = execute_command("LoadProject", {
    project_id = "project_1"
})
assert(result.success, "LoadProject should succeed for project_1")

result = execute_command("LoadProject", {
    project_id = "project_2"
})
assert(result.success, "LoadProject should succeed for project_2")

-- =============================================================================
-- TEST 6: LoadProject is not undoable (no state change to revert)
-- =============================================================================
print("Test 6: LoadProject has no undo (read-only operation)")
-- LoadProject doesn't have an undoer registered, so it should either
-- not be undoable or undo should be a no-op
result = execute_command("LoadProject", {
    project_id = "project_1"
})
assert(result.success, "LoadProject should succeed")

-- Attempting undo after LoadProject - it may succeed (no-op) or fail
-- depending on implementation. The key is it shouldn't error.
command_manager.begin_command_event("script")
local undo_result = command_manager.undo()
command_manager.end_command_event()
-- We don't assert on undo success/failure since LoadProject is read-only

print("\n✅ LoadProject command tests passed")
