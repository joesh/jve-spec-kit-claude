-- SLOW_TEST
-- Integration test: DRP import deduplicates media by UUID across volumes.
-- Uses the anamnesis .drp which has same media at multiple volume paths (~2min).

require("test_env")

local drp_importer = require("importers.drp_importer")
local database = require("core.database")

local test_env = require("test_env")
local fixture_path = test_env.require_fixture(
    "tests/fixtures/resolve/anamnesis joe edit.drp")

local JVP_PATH = "/tmp/jve/test_drp_uuid_dedup.jvp"
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-wal")
os.remove(JVP_PATH .. "-shm")

print("\n=== DRP UUID Media Dedup Integration Test ===")

-- Step 1: Parse — no duplicate UUIDs in media_items
print("\n--- Step 1: Parse DRP ---")
local parse_result = drp_importer.parse_drp_file(fixture_path)
assert(parse_result.success, "parse failed: " .. tostring(parse_result.error))

local total_media = 0
local with_uuid = 0
local with_alt_paths = 0
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
    if item.alt_paths and next(item.alt_paths) then
        with_alt_paths = with_alt_paths + 1
    end
end
print(string.format("  %d media, %d with UUID, %d with alt_paths",
    total_media, with_uuid, with_alt_paths))
assert(with_uuid > 0, "expected some media with UUIDs")
assert(with_alt_paths > 0, "expected some media with alt_paths (cross-volume dedup)")

-- Step 2: Convert to JVP
print("\n--- Step 2: Convert to JVP ---")
local ok, err = drp_importer.convert(fixture_path, JVP_PATH, nil, {audio_sample_rate = 48000})
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
print("\n--- Step 3: Verify DB dedup ---")
local media_count = scalar("SELECT COUNT(*) FROM media")
local uuid_count = scalar("SELECT COUNT(DISTINCT file_uuid) FROM media WHERE file_uuid IS NOT NULL")
print(string.format("  %d media records, %d distinct UUIDs", media_count, uuid_count))

local dup_uuid = scalar([[
    SELECT COUNT(*) FROM (
        SELECT file_uuid, COUNT(*) as cnt FROM media
        WHERE file_uuid IS NOT NULL
        GROUP BY file_uuid HAVING cnt > 1
    )
]])
assert(dup_uuid == 0, string.format("%d duplicate file_uuid values in media table", dup_uuid))

-- Step 4: All timeline clips have media_id
print("\n--- Step 4: Verify clip→media links ---")
local clip_count = scalar("SELECT COUNT(*) FROM clips WHERE clip_kind = 'timeline'")
local orphan_clips = scalar(
    "SELECT COUNT(*) FROM clips WHERE clip_kind = 'timeline' AND media_id IS NULL")
print(string.format("  %d timeline clips, %d orphaned", clip_count, orphan_clips))

-- Step 5: All media have valid frame_rate
local no_fps = scalar("SELECT COUNT(*) FROM media WHERE fps_numerator IS NULL OR fps_numerator <= 0")
assert(no_fps == 0, string.format("%d media records missing frame_rate", no_fps))

-- Step 6: Schema version
local version = scalar("SELECT MAX(version) FROM schema_version")
assert(version == 6, string.format("Expected schema version 6, got %d", version))

print("\n✅ test_drp_uuid_dedup.lua passed")
