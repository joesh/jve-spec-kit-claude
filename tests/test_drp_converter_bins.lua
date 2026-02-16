#!/usr/bin/env luajit

-- Test: DRP converter creates per-sequence master clip bins + imports DRP folder hierarchy

require("test_env")

print("\n=== DRP Converter Bin Creation ===")

local drp_converter = require("importers.drp_importer")
local database = require("core.database")
local tag_service = require("core.tag_service")

local test_env = require("test_env")
local fixture_path = test_env.resolve_repo_path("tests/fixtures/resolve/sample_project.drp")

local JVP_PATH = "/tmp/jve/test_drp_converter_bins.jvp"
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

local passed, failed = 0, 0
local function check(label, condition)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print("  FAIL: " .. label)
    end
end

-- Convert DRP fixture
local ok, err = drp_converter.convert(fixture_path, JVP_PATH)
assert(ok, "drp_converter.convert() failed: " .. tostring(err))

local db = database.get_connection()
assert(db, "No database connection after convert")

local function scalar(sql, param)
    local stmt = assert(db:prepare(sql), "prepare failed: " .. sql)
    if param then stmt:bind_value(1, param) end
    assert(stmt:exec(), "exec failed: " .. sql)
    local val = nil
    if stmt:next() then val = stmt:value(0) end
    stmt:finalize()
    return val
end

-- Get project_id
local project_id = scalar("SELECT id FROM projects LIMIT 1")
check("project exists", project_id ~= nil)

-- ═══════════════════════════════════════════════════════════════
-- 1. Per-sequence master clip bins
-- ═══════════════════════════════════════════════════════════════
print("\n--- 1. Per-sequence master clip bins ---")

-- Get all timeline sequences
local seq_names = {}
local seq_stmt = db:prepare("SELECT name FROM sequences WHERE kind = 'timeline'")
assert(seq_stmt:exec())
while seq_stmt:next() do
    table.insert(seq_names, seq_stmt:value(0))
end
seq_stmt:finalize()
check("has timeline sequences", #seq_names > 0)
print(string.format("  Found %d timeline(s)", #seq_names))

-- Each timeline should have a "{name} Master Clips" bin
local bins = tag_service.list(project_id)
local bins_by_name = {}
for _, bin in ipairs(bins) do
    bins_by_name[bin.name] = bin
end

for _, seq_name in ipairs(seq_names) do
    local expected_bin = seq_name .. " Master Clips"
    check(string.format("bin '%s' exists", expected_bin), bins_by_name[expected_bin] ~= nil)
    if bins_by_name[expected_bin] then
        print(string.format("  ✓ %s (id=%s, parent=%s)",
            expected_bin,
            bins_by_name[expected_bin].id,
            tostring(bins_by_name[expected_bin].parent_id)))
    end
end

-- ═══════════════════════════════════════════════════════════════
-- 2. Master clips assigned to bins
-- ═══════════════════════════════════════════════════════════════
print("\n--- 2. Master clip bin assignments ---")

local mc_map = tag_service.list_master_clip_assignments(project_id)
local assigned_count = 0
for _ in pairs(mc_map) do
    assigned_count = assigned_count + 1
end
print(string.format("  %d master clip(s) have bin assignments", assigned_count))
-- At least some masterclips should be assigned (only clips with media get masterclips)
check("some master clips assigned to bins", assigned_count > 0)

-- ═══════════════════════════════════════════════════════════════
-- 3. DRP folder hierarchy imported as bins
-- ═══════════════════════════════════════════════════════════════
print("\n--- 3. DRP folder hierarchy ---")

-- The fixture should have folders in MediaPool
-- Count total bins (folders + master clip bins)
print(string.format("  Total bins: %d", #bins))
for _, bin in ipairs(bins) do
    print(string.format("    - %s (parent=%s)", bin.name, tostring(bin.parent_id)))
end
-- Should have at least the master clip bins
check("bins created", #bins >= #seq_names)

-- ═══════════════════════════════════════════════════════════════
-- 4. Masterclip sequences still created correctly
-- ═══════════════════════════════════════════════════════════════
print("\n--- 4. Masterclip sequences ---")

local mc_count = scalar("SELECT COUNT(*) FROM sequences WHERE kind = 'masterclip'")
print(string.format("  %d masterclip sequence(s)", mc_count))
check("masterclip sequences exist", mc_count > 0)

-- Cleanup
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("%d test(s) failed", failed))
print("✅ test_drp_converter_bins.lua passed")
