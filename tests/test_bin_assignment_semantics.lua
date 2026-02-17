#!/usr/bin/env luajit

-- Test add_to_bin (INSERT OR IGNORE) vs set_bin (DELETE + INSERT) semantics

require("test_env")

print("=== test_bin_assignment_semantics.lua ===")

local database = require("core.database")
local tag_service = require("core.tag_service")

local TEST_DB = "/tmp/jve/test_bin_assignment_semantics.db"
os.remove(TEST_DB)
database.init(TEST_DB)
local db = database.get_connection()
assert(db, "No database connection")

local schema_sql = require("import_schema")
assert(db:exec(schema_sql))

-- Bootstrap project
assert(db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', strftime('%s','now'), strftime('%s','now'))
]]))

local passed, failed = 0, 0
local function check(label, condition)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print("  FAIL: " .. label)
    end
end

-- Create bins for testing
local ok1, def1 = tag_service.create_bin("proj1", { name = "Bin A" })
check("create Bin A", ok1 and def1)
local bin_a = def1.id

local ok2, def2 = tag_service.create_bin("proj1", { name = "Bin B" })
check("create Bin B", ok2 and def2)
local bin_b = def2.id

-- ═══════════════════════════════════════════════════════════════
-- 1. add_to_bin: INSERT OR IGNORE semantics
-- ═══════════════════════════════════════════════════════════════
print("\n--- 1. add_to_bin (INSERT OR IGNORE) ---")

-- 1a. Add entity to bin A
local ok = database.add_to_bin("proj1", {"mc1"}, bin_a, "master_clip")
check("add mc1 to bin_a", ok)

local bin_map = database.load_master_clip_bin_map("proj1")
check("mc1 in bin_a", bin_map["mc1"] and bin_map["mc1"][1] == bin_a)

-- 1b. Add same entity to bin B (many-to-many: should NOT remove from bin A)
ok = database.add_to_bin("proj1", {"mc1"}, bin_b, "master_clip")
check("add mc1 to bin_b", ok)

-- Both assignments should exist (many-to-many)
-- load_master_clip_bin_map returns {entity_id → {bin_id, ...}}, check count via SQL
local stmt = db:prepare([[
    SELECT COUNT(*) FROM tag_assignments
    WHERE entity_id = 'mc1' AND entity_type = 'master_clip'
]])
assert(stmt:exec())
assert(stmt:next())
local count = stmt:value(0)
stmt:finalize()
check("mc1 has 2 bin assignments (many-to-many)", count == 2)

-- 1c. Idempotent: adding mc1 to bin_a again should NOT create duplicate
ok = database.add_to_bin("proj1", {"mc1"}, bin_a, "master_clip")
check("re-add mc1 to bin_a (idempotent)", ok)

stmt = db:prepare([[
    SELECT COUNT(*) FROM tag_assignments
    WHERE entity_id = 'mc1' AND entity_type = 'master_clip'
]])
assert(stmt:exec())
assert(stmt:next())
count = stmt:value(0)
stmt:finalize()
check("still 2 assignments after re-add", count == 2)

-- ═══════════════════════════════════════════════════════════════
-- 2. set_bin: DELETE + INSERT (move) semantics
-- ═══════════════════════════════════════════════════════════════
print("\n--- 2. set_bin (DELETE + INSERT, move) ---")

-- 2a. set_bin mc1 to bin_a — should remove ALL existing and add just bin_a
ok = database.set_bin("proj1", {"mc1"}, bin_a, "master_clip")
check("set mc1 to bin_a", ok)

stmt = db:prepare([[
    SELECT COUNT(*) FROM tag_assignments
    WHERE entity_id = 'mc1' AND entity_type = 'master_clip'
]])
assert(stmt:exec())
assert(stmt:next())
count = stmt:value(0)
stmt:finalize()
check("mc1 has exactly 1 assignment after set_bin", count == 1)

bin_map = database.load_master_clip_bin_map("proj1")
check("mc1 now in bin_a only", bin_map["mc1"] and #bin_map["mc1"] == 1 and bin_map["mc1"][1] == bin_a)

-- 2b. set_bin to nil — unassign
ok = database.set_bin("proj1", {"mc1"}, nil, "master_clip")
check("set mc1 to nil (unassign)", ok)

stmt = db:prepare([[
    SELECT COUNT(*) FROM tag_assignments
    WHERE entity_id = 'mc1' AND entity_type = 'master_clip'
]])
assert(stmt:exec())
assert(stmt:next())
count = stmt:value(0)
stmt:finalize()
check("mc1 has 0 assignments after unassign", count == 0)

-- ═══════════════════════════════════════════════════════════════
-- 3. tag_service wrappers
-- ═══════════════════════════════════════════════════════════════
print("\n--- 3. tag_service wrappers ---")

ok = tag_service.add_to_bin("proj1", {"mc2"}, bin_a, "master_clip")
check("tag_service.add_to_bin", ok)

ok = tag_service.add_to_bin("proj1", {"mc2"}, bin_b, "master_clip")
check("tag_service.add_to_bin (second bin)", ok)

ok = tag_service.set_bin("proj1", {"mc2"}, bin_a, "master_clip")
check("tag_service.set_bin (move to a)", ok)

bin_map = database.load_master_clip_bin_map("proj1")
check("mc2 in bin_a after set_bin", bin_map["mc2"] and bin_map["mc2"][1] == bin_a)

-- ═══════════════════════════════════════════════════════════════
-- 4. Error cases for add_to_bin
-- ═══════════════════════════════════════════════════════════════
print("\n--- 4. Error cases ---")

-- 4a. Invalid bin_id should assert
local ok4a, err4a = pcall(database.add_to_bin, "proj1", {"mc3"}, "nonexistent_bin", "master_clip")
check("add_to_bin with bad bin asserts", not ok4a)
check("error mentions bin", type(err4a) == "string" and err4a:match("not found"))

-- 4b. nil project_id should assert
local ok4b = pcall(database.add_to_bin, nil, {"mc3"}, bin_a, "master_clip")
check("add_to_bin with nil project asserts", not ok4b)

-- 4c. nil entity_type should assert
local ok4c, err4c = pcall(database.add_to_bin, "proj1", {"mc3"}, bin_a, nil)
check("add_to_bin with nil entity_type asserts", not ok4c)
check("error mentions entity_type", type(err4c) == "string" and err4c:match("entity_type"))

-- 4d. empty entity_ids is no-op (not an error)
local ok4d = database.add_to_bin("proj1", {}, bin_a, "master_clip")
check("add_to_bin with empty entity_ids is no-op", ok4d == true)

-- ═══════════════════════════════════════════════════════════════
-- 5. remove_from_bin
-- ═══════════════════════════════════════════════════════════════
print("\n--- 5. remove_from_bin ---")

-- Setup: mc3 in bin_a and bin_b
database.add_to_bin("proj1", {"mc3"}, bin_a, "master_clip")
database.add_to_bin("proj1", {"mc3"}, bin_b, "master_clip")

-- 5a. Happy path: remove from bin_a only, preserves bin_b
ok = database.remove_from_bin("proj1", {"mc3"}, bin_a, "master_clip")
check("remove_from_bin succeeds", ok)

stmt = db:prepare([[
    SELECT COUNT(*) FROM tag_assignments
    WHERE entity_id = 'mc3' AND entity_type = 'master_clip'
]])
assert(stmt:exec())
assert(stmt:next())
count = stmt:value(0)
stmt:finalize()
check("mc3 has 1 assignment after targeted remove", count == 1)

bin_map = database.load_master_clip_bin_map("proj1")
check("mc3 still in bin_b after removing from bin_a", bin_map["mc3"] and bin_map["mc3"][1] == bin_b)

-- 5b. Remove from bin_b (now mc3 is unassigned)
ok = database.remove_from_bin("proj1", {"mc3"}, bin_b, "master_clip")
check("remove_from_bin bin_b succeeds", ok)

stmt = db:prepare([[
    SELECT COUNT(*) FROM tag_assignments
    WHERE entity_id = 'mc3' AND entity_type = 'master_clip'
]])
assert(stmt:exec())
assert(stmt:next())
count = stmt:value(0)
stmt:finalize()
check("mc3 has 0 assignments after removing from both", count == 0)

-- 5c. Remove from bin that entity is NOT in (no-op, not an error)
ok = database.remove_from_bin("proj1", {"mc3"}, bin_a, "master_clip")
check("remove_from_bin for non-member is no-op", ok)

-- 5d. Empty entity_ids is no-op
ok = database.remove_from_bin("proj1", {}, bin_a, "master_clip")
check("remove_from_bin with empty entity_ids is no-op", ok == true)

-- ═══════════════════════════════════════════════════════════════
-- 6. remove_from_bin error paths
-- ═══════════════════════════════════════════════════════════════
print("\n--- 6. remove_from_bin error paths ---")

-- 6a. nil project_id
local ok6a, err6a = pcall(database.remove_from_bin, nil, {"mc1"}, bin_a, "master_clip")
check("remove_from_bin nil project asserts", not ok6a)
check("error mentions project_id", type(err6a) == "string" and err6a:match("project_id"))

-- 6b. nil bin_id
local ok6b, err6b = pcall(database.remove_from_bin, "proj1", {"mc1"}, nil, "master_clip")
check("remove_from_bin nil bin_id asserts", not ok6b)
check("error mentions bin_id", type(err6b) == "string" and err6b:match("bin_id"))

-- 6c. nil entity_type
local ok6c, err6c = pcall(database.remove_from_bin, "proj1", {"mc1"}, bin_a, nil)
check("remove_from_bin nil entity_type asserts", not ok6c)
check("error mentions entity_type", type(err6c) == "string" and err6c:match("entity_type"))

-- 6d. empty string project_id
local ok6d = pcall(database.remove_from_bin, "", {"mc1"}, bin_a, "master_clip")
check("remove_from_bin empty project asserts", not ok6d)

-- 6e. empty string bin_id
local ok6e = pcall(database.remove_from_bin, "proj1", {"mc1"}, "", "master_clip")
check("remove_from_bin empty bin_id asserts", not ok6e)

-- ═══════════════════════════════════════════════════════════════
-- 7. set_bin error paths
-- ═══════════════════════════════════════════════════════════════
print("\n--- 7. set_bin error paths ---")

-- 7a. nil entity_type
local ok7a, err7a = pcall(database.set_bin, "proj1", {"mc1"}, bin_a, nil)
check("set_bin nil entity_type asserts", not ok7a)
check("error mentions entity_type", type(err7a) == "string" and err7a:match("entity_type"))

-- 7b. empty entity_ids is no-op
local ok7b = database.set_bin("proj1", {}, bin_a, "master_clip")
check("set_bin with empty entity_ids is no-op", ok7b == true)

-- 7c. invalid bin_id
local ok7c = pcall(database.set_bin, "proj1", {"mc1"}, "bad_bin_id", "master_clip")
check("set_bin with bad bin_id errors", not ok7c)

-- Cleanup
os.remove(TEST_DB)

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("%d test(s) failed", failed))
print("✅ test_bin_assignment_semantics.lua passed")
