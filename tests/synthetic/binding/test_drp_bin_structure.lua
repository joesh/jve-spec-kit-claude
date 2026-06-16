-- Integration test: DRP import bin structure matches Resolve's Media Pool.
-- Verifies against the small sample_project fixture (fast — no 41MB parse):
-- 1. All master clips assigned to a bin (no root clutter)
-- 2. "Unorganized" bin is empty (every clip has a pool folder)
-- The anamnesis case (orphans → Unorganized, no sub-folders at root) is folded
-- into test_drp_anamnesis_full Phase 6, which parses that 41MB fixture once.

require("test_env")

local open_project = require("core.commands.open_project")
local database = require("core.database")
local test_env = require("test_env")

print("\n=== DRP Bin Structure Test ===")

-- -----------------------------------------------------------------------
-- Test 1: sample_project.drp — all clips in pool, no orphans
-- -----------------------------------------------------------------------
print("\n--- Test 1: sample_project.drp ---")
do
    local path = test_env.require_fixture("tests/fixtures/resolve/sample_project.drp")
    local jvp = "/tmp/jve/test_bin_structure_sample.jvp"
    os.remove(jvp); os.remove(jvp.."-wal"); os.remove(jvp.."-shm")

    local ok, err = open_project._convert_drp_to_jvp(path, jvp)
    assert(ok, tostring(err))

    local db = database.get_connection()

    -- All master clips should be in bins
    local function scalar(sql)
        local s = assert(db:prepare(sql)); assert(s:exec() and s:next())
        local v = s:value(0); s:finalize(); return v
    end

    local total = scalar("SELECT COUNT(*) FROM sequences WHERE kind = 'master'")
    local assigned = scalar([[
        SELECT COUNT(DISTINCT entity_id) FROM tag_assignments
        WHERE entity_type = 'master_clip'
    ]])
    assert(assigned == total, string.format(
        "sample: expected %d assigned, got %d", total, assigned))
    print(string.format("  %d/%d master clips in bins", assigned, total))

    -- Unorganized bin should exist but be empty (all clips have pool folders)
    local unorg = scalar([[
        SELECT COUNT(*) FROM tag_assignments ta
        JOIN tags t ON ta.tag_id = t.id
        JOIN tag_namespaces ns ON t.namespace_id = ns.id
        WHERE ns.display_name = 'Bins' AND t.name = 'Unorganized'
            AND ta.entity_type = 'master_clip'
    ]])
    assert(unorg == 0, string.format("sample: Unorganized should be empty, got %d", unorg))
    print("  Unorganized bin: 0 clips (correct)")

    database.shutdown()
end

print("\n✅ test_drp_bin_structure.lua passed")
