#!/usr/bin/env luajit

-- Tests for core.smart_bin model: CRUD + evaluate

require("test_env")

local database = require("core.database")
local dkjson = require("dkjson")

local TEST_DB = "/tmp/jve/test_smart_bin.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) VALUES ('proj1', 'Test', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', %d, %d)",
    now, now))
db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) VALUES ('proj2', 'Other', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', %d, %d)",
    now, now))

local smart_bin = require("core.smart_bin")

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

local function expect_error(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL (no error): " .. label .. " — got: " .. tostring(err))
    end
end

print("\n=== Smart Bin Tests ===")

-- ============================================================
-- Test 1: create() inserts record, returns it with id
-- ============================================================
print("\n--- create returns record with id ---")
local criteria = dkjson.encode({
    {column = "codec", operator = "contains", value = "ProRes"},
    {column = "fps", operator = "equals", value = "24"},
})
local sb1 = smart_bin.create(db, {
    project_id = "proj1",
    name = "24fps ProRes",
    criteria_json = criteria,
})
check("create returns table", type(sb1) == "table")
check("create sets id", type(sb1.id) == "string" and #sb1.id > 0)
check("create sets name", sb1.name == "24fps ProRes")
check("create sets project_id", sb1.project_id == "proj1")
check("create sets criteria_json", sb1.criteria_json == criteria)
check("create sets created_at", type(sb1.created_at) == "number")
check("create sets modified_at", type(sb1.modified_at) == "number")
check("scope_bin_id nil by default", sb1.scope_bin_id == nil)

-- ============================================================
-- Test 2: find_by_project() returns all smart bins for project
-- ============================================================
print("\n--- find_by_project ---")
local criteria2 = dkjson.encode({
    {column = "codec", operator = "contains", value = "DNxHD"},
})
local sb2 = smart_bin.create(db, {
    project_id = "proj1",
    name = "DNxHD clips",
    criteria_json = criteria2,
})
local bins = smart_bin.find_by_project(db, "proj1")
check("find_by_project returns 2", #bins == 2)
local found_ids = {}
for _, b in ipairs(bins) do found_ids[b.id] = true end
check("contains sb1", found_ids[sb1.id] == true)
check("contains sb2", found_ids[sb2.id] == true)

-- ============================================================
-- Test 3: find_by_project() returns empty for unknown project
-- ============================================================
print("\n--- find_by_project unknown ---")
local empty = smart_bin.find_by_project(db, "nonexistent_proj")
check("unknown project returns table", type(empty) == "table")
check("unknown project returns empty", #empty == 0)

-- ============================================================
-- Test 4: find_by_id() returns the record
-- ============================================================
print("\n--- find_by_id ---")
local found = smart_bin.find_by_id(db, sb1.id)
check("find_by_id returns table", type(found) == "table")
check("find_by_id correct id", found.id == sb1.id)
check("find_by_id correct name", found.name == "24fps ProRes")
check("find_by_id correct project_id", found.project_id == "proj1")
check("find_by_id correct criteria_json", found.criteria_json == criteria)

-- ============================================================
-- Test 5: find_by_id() returns nil for unknown id
-- ============================================================
print("\n--- find_by_id unknown ---")
local missing = smart_bin.find_by_id(db, "no_such_id")
check("find_by_id unknown returns nil", missing == nil)

-- ============================================================
-- Test 6: update() changes name/criteria
-- ============================================================
print("\n--- update ---")
local new_criteria = dkjson.encode({
    {column = "width", operator = "greater_than", value = "1920"},
})
smart_bin.update(db, sb1.id, {name = "UHD+", criteria_json = new_criteria})
local updated = smart_bin.find_by_id(db, sb1.id)
check("update changes name", updated.name == "UHD+")
check("update changes criteria", updated.criteria_json == new_criteria)
check("update preserves project_id", updated.project_id == "proj1")
check("modified_at advances", updated.modified_at >= sb1.modified_at)

-- ============================================================
-- Test 7: delete() removes the record
-- ============================================================
print("\n--- delete ---")
smart_bin.delete(db, sb2.id)
local deleted = smart_bin.find_by_id(db, sb2.id)
check("delete removes record", deleted == nil)
local remaining = smart_bin.find_by_project(db, "proj1")
check("one remaining after delete", #remaining == 1)
check("remaining is sb1", remaining[1].id == sb1.id)

-- ============================================================
-- Test 8: evaluate() applies criteria and returns matching clip IDs
-- ============================================================
print("\n--- evaluate ---")
local clips = {
    {id = "c1", name = "Shot_A", codec = "ProRes", fps = 24, width = 3840},
    {id = "c2", name = "Shot_B", codec = "DNxHD", fps = 25, width = 1920},
    {id = "c3", name = "Shot_C", codec = "ProRes", fps = 24, width = 1920},
    {id = "c4", name = "Shot_D", codec = "H264", fps = 30, width = 3840},
}

-- sb1 was updated to UHD+ (width > 1920)
local uhd_ids = smart_bin.evaluate(updated, clips)
check("evaluate returns table", type(uhd_ids) == "table")
check("evaluate matches 2 UHD clips", #uhd_ids == 2)
local uhd_set = {}
for _, cid in ipairs(uhd_ids) do uhd_set[cid] = true end
check("c1 matches UHD", uhd_set["c1"] == true)
check("c4 matches UHD", uhd_set["c4"] == true)

-- Create a smart bin with multi-criteria (AND logic): ProRes AND 24fps
local multi_sb = smart_bin.create(db, {
    project_id = "proj1",
    name = "ProRes 24",
    criteria_json = dkjson.encode({
        {column = "codec", operator = "contains", value = "ProRes"},
        {column = "fps", operator = "equals", value = "24"},
    }),
})
local multi_ids = smart_bin.evaluate(multi_sb, clips)
check("multi-criteria matches 2", #multi_ids == 2)
local multi_set = {}
for _, cid in ipairs(multi_ids) do multi_set[cid] = true end
check("c1 matches ProRes 24", multi_set["c1"] == true)
check("c3 matches ProRes 24", multi_set["c3"] == true)

-- Empty criteria matches all
local all_sb = smart_bin.create(db, {
    project_id = "proj1",
    name = "Everything",
    criteria_json = "[]",
})
local all_ids = smart_bin.evaluate(all_sb, clips)
check("empty criteria matches all", #all_ids == 4)

-- ============================================================
-- Test 9: scope tests deferred to integration
-- ============================================================
print("\n--- scope_bin_id (basic) ---")
-- Create a real tag for FK constraint
local tag_ns_stmt = db:prepare("INSERT OR IGNORE INTO tag_namespaces (id, display_name) VALUES ('bin', 'Bins')")
tag_ns_stmt:exec()
tag_ns_stmt:finalize()
local tag_stmt = db:prepare("INSERT INTO tags (id, project_id, namespace_id, name, path) VALUES ('test_tag_1', 'proj1', 'bin', 'TestBin', '/TestBin')")
tag_stmt:exec()
tag_stmt:finalize()

local scoped_sb = smart_bin.create(db, {
    project_id = "proj1",
    name = "Scoped Bin",
    criteria_json = "[]",
    scope_bin_id = "test_tag_1",
})
check("scoped create sets scope_bin_id", scoped_sb.scope_bin_id == "test_tag_1")
-- Note: scope filtering (limiting evaluate to clips in a bin) deferred to integration tests
-- because it requires tag_assignments + tag_service wiring.
smart_bin.delete(db, scoped_sb.id)

-- ============================================================
-- Test 10: create() with empty name asserts (CHECK constraint)
-- ============================================================
print("\n--- empty name errors ---")
expect_error("create with empty name", function()
    smart_bin.create(db, {
        project_id = "proj1",
        name = "",
        criteria_json = "[]",
    })
end)

-- ============================================================
-- Test 11: multiple smart bins per project
-- ============================================================
print("\n--- multiple bins per project ---")
local sb_a = smart_bin.create(db, {
    project_id = "proj2",
    name = "Bin Alpha",
    criteria_json = dkjson.encode({{column = "name", operator = "begins_with", value = "A"}}),
})
local sb_b = smart_bin.create(db, {
    project_id = "proj2",
    name = "Bin Beta",
    criteria_json = dkjson.encode({{column = "name", operator = "ends_with", value = "B"}}),
})
local sb_c = smart_bin.create(db, {
    project_id = "proj2",
    name = "Bin Gamma",
    criteria_json = dkjson.encode({{column = "codec", operator = "matches_exactly", value = "H264"}}),
})
local proj2_bins = smart_bin.find_by_project(db, "proj2")
check("proj2 has 3 bins", #proj2_bins == 3)

-- Verify isolation: proj1 bins unchanged
local proj1_bins = smart_bin.find_by_project(db, "proj1")
local proj1_count = #proj1_bins
-- sb1 (updated) + multi_sb + all_sb = 3 remaining in proj1
check("proj1 still has 3 bins", proj1_count == 3)

-- Evaluate each proj2 bin
local test_clips = {
    {id = "x1", name = "Alpha_1", codec = "ProRes", fps = 24},
    {id = "x2", name = "Clip_B", codec = "H264", fps = 30},
    {id = "x3", name = "Another", codec = "DNxHD", fps = 25},
}

local alpha_ids = smart_bin.evaluate(sb_a, test_clips)
-- "Alpha_1" and "Another" both begin with "A"
check("Alpha bin matches 2", #alpha_ids == 2)

local beta_ids = smart_bin.evaluate(sb_b, test_clips)
check("Beta bin matches 1", #beta_ids == 1)
check("Beta matches x2", beta_ids[1] == "x2")

local gamma_ids = smart_bin.evaluate(sb_c, test_clips)
check("Gamma bin matches 1", #gamma_ids == 1)
check("Gamma matches x2", gamma_ids[1] == "x2")

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Smart Bin: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_smart_bin.lua passed")
