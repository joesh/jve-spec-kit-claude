-- SLOW_TEST
-- Integration test: DRP import bin structure matches Resolve's Media Pool.
-- Verifies:
-- 1. Root bins match DRP folder hierarchy (no sub-folders at root)
-- 2. All master clips assigned to a bin (no root clutter)
-- 3. Orphaned media (not in pool) goes to "Unorganized" bin

require("test_env")

local drp = require("importers.drp_importer")
local database = require("core.database")
local test_env = require("test_env")

print("\n=== DRP Bin Structure Test ===")

-- -----------------------------------------------------------------------
-- Test 1: sample_project.drp — all clips in pool, no orphans
-- -----------------------------------------------------------------------
print("\n--- Test 1: sample_project.drp ---")
do
    local path = test_env.resolve_repo_path("tests/fixtures/resolve/sample_project.drp")
    local jvp = "/tmp/jve/test_bin_structure_sample.jvp"
    os.remove(jvp); os.remove(jvp.."-wal"); os.remove(jvp.."-shm")

    local ok, err = drp.convert(path, jvp)
    assert(ok, tostring(err))

    local db = database.get_connection()

    -- All master clips should be in bins
    local function scalar(sql)
        local s = assert(db:prepare(sql)); assert(s:exec() and s:next())
        local v = s:value(0); s:finalize(); return v
    end

    local total = scalar("SELECT COUNT(*) FROM sequences WHERE kind = 'masterclip'")
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

-- -----------------------------------------------------------------------
-- Test 2: anamnesis — has orphaned media → Unorganized bin
-- -----------------------------------------------------------------------
print("\n--- Test 2: anamnesis DRP ---")
do
    local path = test_env.resolve_repo_path(
        "tests/fixtures/resolve/2026-03-01-anamnesis joe edit.drp")
    local jvp = "/tmp/jve/test_bin_structure_anam.jvp"
    os.remove(jvp); os.remove(jvp.."-wal"); os.remove(jvp.."-shm")

    local ok, err = drp.convert(path, jvp)
    assert(ok, tostring(err))

    local db = database.get_connection()

    local function scalar(sql)
        local s = assert(db:prepare(sql)); assert(s:exec() and s:next())
        local v = s:value(0); s:finalize(); return v
    end

    -- All master clips in bins
    local total = scalar("SELECT COUNT(*) FROM sequences WHERE kind = 'masterclip'")
    local assigned = scalar([[
        SELECT COUNT(DISTINCT entity_id) FROM tag_assignments
        WHERE entity_type = 'master_clip'
    ]])
    assert(assigned == total, string.format(
        "anam: expected %d assigned, got %d", total, assigned))
    print(string.format("  %d/%d master clips in bins", assigned, total))

    -- Unorganized bin should have the orphaned clips
    local unorg = scalar([[
        SELECT COUNT(*) FROM tag_assignments ta
        JOIN tags t ON ta.tag_id = t.id
        JOIN tag_namespaces ns ON t.namespace_id = ns.id
        WHERE ns.display_name = 'Bins' AND t.name = 'Unorganized'
            AND ta.entity_type = 'master_clip'
    ]])
    assert(unorg > 0, "anam: Unorganized should have orphaned clips")
    print(string.format("  Unorganized bin: %d clips", unorg))

    -- Root bins should NOT include sub-folders like A020, A026-2
    local root_bins = {}
    local stmt = assert(db:prepare([[
        SELECT t.name FROM tags t
        JOIN tag_namespaces ns ON t.namespace_id = ns.id
        WHERE ns.display_name = 'Bins' AND t.parent_id IS NULL
        ORDER BY t.name
    ]]))
    assert(stmt:exec())
    while stmt:next() do root_bins[#root_bins+1] = stmt:value(0) end
    stmt:finalize()

    print("  Root bins: " .. table.concat(root_bins, ", "))
    for _, name in ipairs(root_bins) do
        assert(name ~= "A020" and name ~= "A026-2" and name ~= "A027" and name ~= "A029",
            "Sub-folder '" .. name .. "' should not be at root level")
    end
    print("  No sub-folders at root (correct)")

    database.shutdown()
end

print("\n✅ test_drp_bin_structure.lua passed")
