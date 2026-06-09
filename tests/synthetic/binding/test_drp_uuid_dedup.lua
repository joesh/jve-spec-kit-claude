-- Integration test: DRP import deduplicates media by UUID.
-- Uses the small sample_project.drp fixture for fast execution.
-- Full test with large anamnesis DRP: tests/slow/test_drp_uuid_dedup_full.lua

require("test_env")

local drp_importer = require("importers.drp_importer")
local database = require("core.database")

local test_env = require("test_env")
local fixture_path = test_env.resolve_repo_path(
    "tests/fixtures/resolve/sample_project.drp")

local JVP_PATH = "/tmp/jve/test_drp_uuid_dedup.jvp"
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print("\n=== DRP UUID Media Dedup Test (fast) ===")

-- Step 1: Parse — media_items is a hash table, no duplicate UUIDs
print("\n--- Step 1: Parse DRP ---")
local parse_result = drp_importer.parse_drp_file(fixture_path)
assert(parse_result.success, "parse failed: " .. tostring(parse_result.error))

local total_media = 0
local with_uuid = 0
local uuid_set = {}
for _, item in pairs(parse_result.media_items) do
    total_media = total_media + 1
    if item.file_uuid and item.file_uuid ~= "" then
        with_uuid = with_uuid + 1
        assert(not uuid_set[item.file_uuid],
            string.format("Duplicate UUID %s: path1=%s path2=%s",
                item.file_uuid, uuid_set[item.file_uuid], item.file_path))
        uuid_set[item.file_uuid] = item.file_path
    end
end
print(string.format("  %d media, %d with UUID", total_media, with_uuid))
assert(next(parse_result.media_items), "expected some media items")

-- Step 2: Convert to JVP
print("\n--- Step 2: Convert to JVP ---")
local ok, err = require("core.commands.open_project")._convert_drp_to_jvp(
    fixture_path, JVP_PATH, nil, {audio_sample_rate = 48000})
assert(ok, "convert failed: " .. tostring(err))

local db = database.get_connection()
assert(db, "No database connection after convert")

local function scalar(sql)
    local stmt = assert(db:prepare(sql))
    assert(stmt:exec())
    local val = nil
    if stmt:next() then val = stmt:value(0) end
    stmt:finalize()
    return val
end

-- Step 3: No duplicate UUIDs in DB
print("\n--- Step 3: Verify DB ---")
local media_count = scalar("SELECT COUNT(*) FROM media")
print(string.format("  %d media records", media_count))

local dup_uuid = scalar([[
    SELECT COUNT(*) FROM (
        SELECT file_uuid, COUNT(*) as cnt FROM media
        WHERE file_uuid IS NOT NULL
        GROUP BY file_uuid HAVING cnt > 1
    )
]])
assert(dup_uuid == 0, string.format("%d duplicate file_uuid values", dup_uuid))

-- All media have valid frame_rate
local no_fps = scalar("SELECT COUNT(*) FROM media WHERE fps_numerator IS NULL OR fps_numerator <= 0")
assert(no_fps == 0, string.format("%d media missing frame_rate", no_fps))

-- Schema version (match core/database.lua)
test_env.assert_schema_version(db)

print("\n✅ test_drp_uuid_dedup.lua passed")
