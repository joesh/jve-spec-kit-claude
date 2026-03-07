#!/usr/bin/env luajit

-- NSF regression: DRP import bin assignment bugs
--
-- Bug 1: Master clips not assigned to DRP folder bins (only to per-sequence bins)
-- Bug 2: Timeline sequences not assigned to DRP folder bins (appear at root)
-- Bug 3: "Master" root folder should not be created as a bin

require("test_env")

print("\n=== test_drp_import_bin_assignments.lua ===")

local drp_converter = require("importers.drp_importer")
local database = require("core.database")
local tag_service = require("core.tag_service")

local test_env = require("test_env")
local fixture_path = test_env.resolve_repo_path("tests/fixtures/resolve/sample_project.drp")

local JVP_PATH = "/tmp/jve/test_drp_import_bin_assignments.jvp"
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

local function scalar(sql, ...)
    local stmt = assert(db:prepare(sql), "prepare failed: " .. sql)
    local params = {...}
    for i, v in ipairs(params) do stmt:bind_value(i, v) end
    assert(stmt:exec(), "exec failed: " .. sql)
    local val = nil
    if stmt:next() then val = stmt:value(0) end
    stmt:finalize()
    return val
end

local function query_pairs(sql, ...)
    local stmt = assert(db:prepare(sql), "prepare failed: " .. sql)
    local params = {...}
    for i, v in ipairs(params) do stmt:bind_value(i, v) end
    assert(stmt:exec(), "exec failed: " .. sql)
    local rows = {}
    while stmt:next() do
        table.insert(rows, { col0 = stmt:value(0), col1 = stmt:value(1) })
    end
    stmt:finalize()
    return rows
end

local project_id = scalar("SELECT id FROM projects LIMIT 1")
assert(project_id, "no project found")

-- Load all bins
local bins = tag_service.list(project_id)
local bins_by_name = {}
for _, bin in ipairs(bins) do
    bins_by_name[bin.name] = bin
end

-- ═══════════════════════════════════════════════════════════════
-- Bug 3: "Master" root folder should NOT be a bin
-- ═══════════════════════════════════════════════════════════════
print("\n--- Bug 3: Master root excluded ---")

check("no 'Master' bin exists", bins_by_name["Master"] == nil)

-- DRP subfolders (Audio, Footage, Graphics, audio tracks test) should be root bins
-- (Their parent was Master, which is excluded, so they become root)
local drp_folder_names = {"Audio", "Footage", "Graphics", "audio tracks test"}
for _, name in ipairs(drp_folder_names) do
    local bin = bins_by_name[name]
    if bin then
        check(string.format("'%s' is root bin (parent=nil)", name), bin.parent_id == nil)
    end
end

-- ═══════════════════════════════════════════════════════════════
-- Bug 1: Master clips should be in DRP folder bins
-- ═══════════════════════════════════════════════════════════════
print("\n--- Bug 1: Master clips in DRP folder bins ---")

-- The DRP pool master clips have folder assignments.
-- After import, masterclip sequences should be in those folder bins.
-- E.g., pool master clip "A001_05191411_C020.mov" is in DRP folder "Footage"
--   → its masterclip sequence should be assigned to the "Footage" bin.

-- Query all masterclip sequences (col0=id, col1=name)
local masterclip_seqs = query_pairs(
    "SELECT id, name FROM sequences WHERE kind = 'masterclip' AND project_id = ?",
    project_id)

-- Query all bin assignments for master_clip entity_type (col0=entity_id, col1=tag_id)
local assignments = query_pairs([[
    SELECT entity_id, tag_id FROM tag_assignments
    WHERE project_id = ? AND namespace_id = 'bin' AND entity_type = 'master_clip'
]], project_id)

-- Build assignment lookup: entity_id -> list of bin_ids
local entity_bins = {}
for _, a in ipairs(assignments) do
    entity_bins[a.col0] = entity_bins[a.col0] or {}
    table.insert(entity_bins[a.col0], a.col1)
end

-- Build bin_id -> name lookup
local bin_id_to_name = {}
for _, bin in ipairs(bins) do
    bin_id_to_name[bin.id] = bin.name
end

-- Check: masterclip sequences should have assignments to DRP folder bins
-- (not just per-sequence master clip bins)
local mc_in_drp_folder = 0
for _, mc in ipairs(masterclip_seqs) do
    local mc_bins = entity_bins[mc.col0] or {}
    for _, bid in ipairs(mc_bins) do
        local bname = bin_id_to_name[bid] or ""
        -- DRP folder bins don't end with "Master Clips"
        if not bname:match("Master Clips$") then
            mc_in_drp_folder = mc_in_drp_folder + 1
            break
        end
    end
end

print(string.format("  %d/%d masterclip seqs in DRP folder bins", mc_in_drp_folder, #masterclip_seqs))
check("some masterclips assigned to DRP folder bins", mc_in_drp_folder > 0)

-- Specific check: a clip we know is in "Footage" from the parse result
-- Find masterclip seq for a media with "A001" in the name (known to be in Footage)
local footage_bin = bins_by_name["Footage"]
if footage_bin then
    local footage_mc = scalar([[
        SELECT s.id FROM sequences s
        JOIN media m ON s.name = m.name
        WHERE s.kind = 'masterclip' AND m.name LIKE 'A001%'
        LIMIT 1
    ]])
    if footage_mc then
        local in_footage = scalar([[
            SELECT COUNT(*) FROM tag_assignments
            WHERE entity_id = ? AND tag_id = ? AND entity_type = 'master_clip'
        ]], footage_mc, footage_bin.id)
        check("A001 masterclip is in Footage bin", (in_footage or 0) > 0)
    else
        print("  (no A001 masterclip found, skipping specific check)")
    end
else
    print("  (no Footage bin found, skipping specific check)")
end

-- ═══════════════════════════════════════════════════════════════
-- Bug 2: Timeline sequences should be in DRP folder bins
-- ═══════════════════════════════════════════════════════════════
print("\n--- Bug 2: Sequences in DRP folder bins ---")

-- Timeline sequences should be assigned to bins via entity_type = "sequence"
local seq_assignments = query_pairs([[
    SELECT entity_id, tag_id FROM tag_assignments
    WHERE project_id = ? AND namespace_id = 'bin' AND entity_type = 'sequence'
]], project_id)

local timelines = query_pairs(
    "SELECT id, name FROM sequences WHERE kind = 'timeline' AND project_id = ?",
    project_id)

print(string.format("  %d timeline(s), %d sequence bin assignment(s)", #timelines, #seq_assignments))
check("timeline sequences have bin assignments", #seq_assignments > 0)

-- Build seq assignment lookup
local seq_bin_map = {}
for _, a in ipairs(seq_assignments) do
    seq_bin_map[a.col0] = a.col1
end

-- Each timeline with a folder_id in parse result should be in a bin
local timelines_in_bins = 0
for _, tl in ipairs(timelines) do
    if seq_bin_map[tl.col0] then
        timelines_in_bins = timelines_in_bins + 1
        local bname = bin_id_to_name[seq_bin_map[tl.col0]] or "?"
        print(string.format("  ✓ '%s' in bin '%s'", tl.col1, bname))
    else
        print(string.format("  ✗ '%s' NOT in any bin", tl.col1))
    end
end
check("at least some timelines in bins", timelines_in_bins > 0)

-- Cleanup
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("%d test(s) failed", failed))
print("✅ test_drp_import_bin_assignments.lua passed")
