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
check("mc1 in bin_a", bin_map["mc1"] == bin_a)

-- 1b. Add same entity to bin B (many-to-many: should NOT remove from bin A)
ok = database.add_to_bin("proj1", {"mc1"}, bin_b, "master_clip")
check("add mc1 to bin_b", ok)

-- Both assignments should exist (many-to-many)
-- load_master_clip_bin_map returns only one mapping (last wins), so check via SQL
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
check("mc1 now in bin_a only", bin_map["mc1"] == bin_a)

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
check("mc2 in bin_a after set_bin", bin_map["mc2"] == bin_a)

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

-- Cleanup
os.remove(TEST_DB)

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("%d test(s) failed", failed))
print("✅ test_bin_assignment_semantics.lua passed")
