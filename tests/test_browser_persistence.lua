--- Test: browser_persistence — sort state + expanded bins round-trip through project settings
require("test_env")

local database = require("core.database")
local import_schema = require("import_schema")

print("Testing browser persistence...")

-- Set up test database
local test_db = "/tmp/jve/test_browser_persistence.jvp"
os.execute("rm -f " .. test_db .. "*")
assert(database.set_path(test_db), "failed to set db path")
local conn = database.get_connection()
assert(conn, "failed to open db connection")
assert(conn:exec(import_schema), "failed to apply schema")

-- Create a project
local project_id = "test-project-persist"
local now = os.time()
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, settings) VALUES ('%s', 'Test Project', %d, %d, '{}')",
    project_id, now, now)))

-- 1. Sort state round-trip
print("  sort state round-trip...")
do
    database.set_project_setting(project_id, "browser_sort_primary_column", 1)
    database.set_project_setting(project_id, "browser_sort_primary_order", "desc")
    database.set_project_setting(project_id, "browser_sort_secondary_column", 3)
    database.set_project_setting(project_id, "browser_sort_secondary_order", "asc")

    local settings = database.get_project_settings(project_id)
    assert(settings.browser_sort_primary_column == 1,
        "primary_column: " .. tostring(settings.browser_sort_primary_column))
    assert(settings.browser_sort_primary_order == "desc",
        "primary_order: " .. tostring(settings.browser_sort_primary_order))
    assert(settings.browser_sort_secondary_column == 3,
        "secondary_column: " .. tostring(settings.browser_sort_secondary_column))
    assert(settings.browser_sort_secondary_order == "asc",
        "secondary_order: " .. tostring(settings.browser_sort_secondary_order))
end

-- 2. Sort state with nil secondary
print("  sort state with nil secondary...")
do
    database.set_project_setting(project_id, "browser_sort_secondary_column", nil)
    database.set_project_setting(project_id, "browser_sort_secondary_order", nil)

    local settings = database.get_project_settings(project_id)
    assert(settings.browser_sort_secondary_column == nil,
        "secondary_column nil: " .. tostring(settings.browser_sort_secondary_column))
    assert(settings.browser_sort_secondary_order == nil,
        "secondary_order nil: " .. tostring(settings.browser_sort_secondary_order))
    -- Primary still intact
    assert(settings.browser_sort_primary_column == 1)
    assert(settings.browser_sort_primary_order == "desc")
end

-- 3. Expanded bins round-trip
print("  expanded bins round-trip...")
do
    local expanded = {"bin-1", "bin-3", "bin-5"}
    database.set_project_setting(project_id, "browser_expanded_bins", expanded)

    local settings = database.get_project_settings(project_id)
    local saved = settings.browser_expanded_bins
    assert(type(saved) == "table", "expanded_bins is table")
    assert(#saved == 3, "3 expanded bins: got " .. #saved)
    assert(saved[1] == "bin-1")
    assert(saved[2] == "bin-3")
    assert(saved[3] == "bin-5")
end

-- 4. Empty expanded bins
print("  empty expanded bins...")
do
    database.set_project_setting(project_id, "browser_expanded_bins", {})

    local settings = database.get_project_settings(project_id)
    local saved = settings.browser_expanded_bins
    assert(type(saved) == "table", "expanded_bins is table")
    assert(#saved == 0, "0 expanded bins")
end

-- Cleanup
os.execute("rm -f " .. test_db .. "*")

print("\xE2\x9C\x85 test_browser_persistence.lua passed")
