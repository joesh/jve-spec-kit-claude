#!/usr/bin/env luajit

-- NSF regression: MoveToBin must preserve other bin assignments (many-to-many).
--
-- Scenario: mc1 is in Bin A and Bin B. MoveToBin(mc1, target=Bin C).
-- Expected: mc1 is in Bin B and Bin C (only Bin A removed).
-- Bug: set_bin nukes ALL assignments, so mc1 ends up only in Bin C.

require("test_env")

print("=== test_move_to_bin_preserves_multi.lua ===")

local database = require("core.database")
local tag_service = require("core.tag_service")
local command_manager = require("core.command_manager")
local Command = require("command")

local TEST_DB = "/tmp/jve/test_move_to_bin_preserves_multi.db"
os.remove(TEST_DB)
database.init(TEST_DB)
local db = database.get_connection()
assert(db, "No database connection")

local schema_sql = require("import_schema")
assert(db:exec(schema_sql))

-- Bootstrap project + sequence
assert(db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
                          audio_rate, width, height, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Timeline', 'timeline', 24, 1, 48000, 1920, 1080,
            strftime('%s','now'), strftime('%s','now'));
]]))

command_manager.init("seq1", "proj1")

local passed, failed = 0, 0
local function check(label, condition)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print("  FAIL: " .. label)
    end
end

local function count_assignments(entity_id)
    local stmt = db:prepare([[
        SELECT COUNT(*) FROM tag_assignments
        WHERE entity_id = ? AND entity_type = 'master_clip'
    ]])
    assert(stmt, "prepare failed")
    stmt:bind_value(1, entity_id)
    assert(stmt:exec())
    assert(stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

local function assignment_exists(entity_id, bin_id)
    local stmt = db:prepare([[
        SELECT COUNT(*) FROM tag_assignments
        WHERE entity_id = ? AND tag_id = ? AND entity_type = 'master_clip'
    ]])
    assert(stmt, "prepare failed")
    stmt:bind_value(1, entity_id)
    stmt:bind_value(2, bin_id)
    assert(stmt:exec())
    assert(stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n > 0
end

-- Create bins
local ok_a, def_a = tag_service.create_bin("proj1", { name = "Bin A" })
assert(ok_a and def_a, "create Bin A failed")
local bin_a = def_a.id

local ok_b, def_b = tag_service.create_bin("proj1", { name = "Bin B" })
assert(ok_b and def_b, "create Bin B failed")
local bin_b = def_b.id

local ok_c, def_c = tag_service.create_bin("proj1", { name = "Bin C" })
assert(ok_c and def_c, "create Bin C failed")
local bin_c = def_c.id

-- Setup: mc1 in Bin A AND Bin B (many-to-many via add_to_bin)
database.add_to_bin("proj1", {"mc1"}, bin_a, "master_clip")
database.add_to_bin("proj1", {"mc1"}, bin_b, "master_clip")

check("precondition: mc1 has 2 assignments", count_assignments("mc1") == 2)
check("precondition: mc1 in bin_a", assignment_exists("mc1", bin_a))
check("precondition: mc1 in bin_b", assignment_exists("mc1", bin_b))

-- ═══════════════════════════════════════════════════════════════
-- Test: MoveToBin(mc1, target=Bin C) should only remove from current bin,
-- not nuke all assignments.
-- ═══════════════════════════════════════════════════════════════
print("\n--- MoveToBin with many-to-many ---")

-- MoveToBin uses source_bin_id to know which bin to remove from.
-- It should remove mc1 from Bin A and add to Bin C, preserving Bin B.

local cmd = Command.create("MoveToBin", "proj1")
cmd:set_parameter("entity_ids", {"mc1"})
cmd:set_parameter("target_bin_id", bin_c)
cmd:set_parameter("source_bin_id", bin_a)
cmd:set_parameter("project_id", "proj1")

local result = command_manager.execute(cmd)
check("MoveToBin executed", result ~= false and result ~= nil)

-- After move: mc1 should be in Bin B and Bin C (NOT just Bin C)
check("mc1 NOT in bin_a after move", not assignment_exists("mc1", bin_a))
check("mc1 still in bin_b (preserved)", assignment_exists("mc1", bin_b))
check("mc1 in bin_c (new)", assignment_exists("mc1", bin_c))
check("mc1 has 2 assignments after move", count_assignments("mc1") == 2)

-- ═══════════════════════════════════════════════════════════════
-- Test: Undo should restore mc1 to Bin A + Bin B (remove Bin C, add Bin A)
-- ═══════════════════════════════════════════════════════════════
print("\n--- Undo MoveToBin ---")

command_manager.undo()

check("mc1 in bin_a after undo", assignment_exists("mc1", bin_a))
check("mc1 in bin_b after undo (preserved)", assignment_exists("mc1", bin_b))
check("mc1 NOT in bin_c after undo", not assignment_exists("mc1", bin_c))
check("mc1 has 2 assignments after undo", count_assignments("mc1") == 2)

-- ═══════════════════════════════════════════════════════════════
-- Test: Redo should re-apply: mc1 in Bin B + Bin C
-- ═══════════════════════════════════════════════════════════════
print("\n--- Redo MoveToBin ---")

command_manager.redo()

check("mc1 NOT in bin_a after redo", not assignment_exists("mc1", bin_a))
check("mc1 in bin_b after redo (preserved)", assignment_exists("mc1", bin_b))
check("mc1 in bin_c after redo (restored)", assignment_exists("mc1", bin_c))
check("mc1 has 2 assignments after redo", count_assignments("mc1") == 2)

-- Cleanup
os.remove(TEST_DB)

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("%d test(s) failed", failed))
print("✅ test_move_to_bin_preserves_multi.lua passed")
