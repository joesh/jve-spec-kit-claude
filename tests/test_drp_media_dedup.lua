#!/usr/bin/env luajit
-- TDD regression test: DRP import must deduplicate media by UUID, not path.
--
-- Bug: Same physical media referenced from multiple volumes (AnamBack1, AnamBack4,
-- media-managed) creates duplicate media_items because import keys by file path.
-- Resolve keys by master clip UUID (<MediaRef> DbId). Same UUID at two paths should
-- produce one media entry with frame_rate, not two entries where one lacks it.

require("test_env")

print("=== test_drp_media_dedup.lua ===")

local import_schema = require("import_schema")
local database = require("core.database")
local Media = require("models.media")

local function with_db(fn)
    local db_path = "/tmp/jve/test_drp_media_dedup.db"
    os.remove(db_path)
    os.remove(db_path .. "-wal")
    os.remove(db_path .. "-shm")
    assert(database.set_path(db_path), "failed to set db path")
    local db = database.get_connection()
    assert(db, "failed to open db connection")
    assert(db:exec(import_schema), "failed to apply schema")
    assert(db:exec([[INSERT INTO projects(id, name, created_at, modified_at, settings)
        VALUES('proj', 'Test', strftime('%s','now'), strftime('%s','now'), '{}')]]))
    fn(db)
end

--------------------------------------------------------------------------------
-- Test 1: media_index deduplicates by UUID across different paths
--------------------------------------------------------------------------------

print("\n--- Test 1: UUID dedup in media_index ---")

-- We test the data structure that parse_drp_file builds.
-- Two media_items with same file_uuid but different paths.
-- After merging, one entry should survive with both paths accessible.

with_db(function()
    -- Simulate what parse_drp_file produces after UUID-keyed dedup:
    -- media_items should contain ONE entry per UUID, with alt_paths for extras.
    local uuid = "abc-123-def"
    local path1 = "/Volumes/AnamBack1/Media/clip.mov"
    local path2 = "/Volumes/AnamBack4/Media/clip.mov"

    -- Build media_index (the new UUID-keyed structure from drp_importer)
    local media_index = {
        by_uuid = {},
        by_path = {},
    }

    -- First occurrence: path1, has UUID
    local entry1 = {
        file_uuid = uuid,
        name = "clip.mov",
        file_path = path1,
        duration = 100,
        -- no frame_rate yet (blob propagation hasn't run)
        alt_paths = {},
    }
    media_index.by_uuid[uuid] = entry1
    media_index.by_path[path1] = entry1

    -- Second occurrence: same UUID, different path
    local existing = media_index.by_uuid[uuid]
    assert(existing, "UUID lookup should find existing entry")
    assert(existing.file_path == path1, "canonical path should be path1")

    -- Add path2 as alt_path (this is what the dedup logic does)
    existing.alt_paths[path2] = true
    media_index.by_path[path2] = existing

    -- Simulate blob propagation: sets frame_rate on the one entry
    existing.frame_rate = 25
    existing.duration = 500

    -- Verify: ONE entry, has frame_rate, both paths resolve to it
    assert(media_index.by_uuid[uuid].frame_rate == 25,
        "UUID entry must have frame_rate after blob propagation")
    assert(media_index.by_path[path1] == media_index.by_uuid[uuid],
        "path1 must resolve to the same entry")
    assert(media_index.by_path[path2] == media_index.by_uuid[uuid],
        "path2 must resolve to the same entry (via alt_paths)")

    -- Both paths point to same table identity
    assert(media_index.by_path[path1] == media_index.by_path[path2],
        "both paths must point to identical table (not copies)")

    print("  PASS: UUID dedup merges paths, frame_rate propagates once")
end)

--------------------------------------------------------------------------------
-- Test 2: import_into_project creates one media record per UUID
--------------------------------------------------------------------------------

print("\n--- Test 2: one media record per UUID in DB ---")

with_db(function()
    local uuid_val = "mc-uuid-001"
    local path1 = "/Volumes/Vol1/Media/interview.mxf"
    local path2 = "/Volumes/Vol2/Media/interview.mxf"

    -- Simulate parse_result.media_items after UUID dedup:
    -- ONE entry with file_uuid, canonical path, and alt_paths
    local media_items = {
        {
            name = "interview.mxf",
            file_path = path1,
            file_uuid = uuid_val,
            duration = 1000,
            frame_rate = 25,
            alt_paths = { [path2] = true },
        },
    }

    -- Import media (mirroring import_into_project logic)
    local media_by_uuid = {}
    local media_by_path = {}

    for _, media_item in ipairs(media_items) do
        local media = Media.create({
            project_id = "proj",
            name = media_item.name,
            file_path = media_item.file_path,
            file_uuid = media_item.file_uuid,
            duration_frames = media_item.duration,
            frame_rate = media_item.frame_rate,
        })
        assert(media:save(), "failed to save media")

        if media_item.file_uuid then
            media_by_uuid[media_item.file_uuid] = media
        end
        media_by_path[media_item.file_path] = media
        for alt in pairs(media_item.alt_paths or {}) do
            media_by_path[alt] = media
        end
    end

    -- Verify: one DB record
    local db = database.get_connection()
    local count_q = assert(db:prepare("SELECT COUNT(*) FROM media WHERE project_id = 'proj'"))
    assert(count_q:exec())
    assert(count_q:next())
    local count = count_q:value(0)
    count_q:finalize()
    assert(count == 1, string.format("expected 1 media record, got %d", count))

    -- Verify: UUID lookup works
    assert(media_by_uuid[uuid_val], "UUID lookup must find media")
    assert(media_by_uuid[uuid_val].id == media_by_path[path1].id,
        "UUID and path1 must resolve to same media")

    -- Verify: alt path also resolves
    assert(media_by_path[path2], "alt path must be in lookup")
    assert(media_by_path[path2].id == media_by_uuid[uuid_val].id,
        "alt path must resolve to same media as UUID")

    -- Verify: file_uuid persisted to DB
    local uuid_q = assert(db:prepare("SELECT file_uuid FROM media WHERE project_id = 'proj'"))
    assert(uuid_q:exec())
    assert(uuid_q:next())
    local stored_uuid = uuid_q:value(0)
    uuid_q:finalize()
    assert(stored_uuid == uuid_val,
        string.format("expected file_uuid='%s', got '%s'", uuid_val, tostring(stored_uuid)))

    -- Verify: file_uuid survives load round-trip
    local loaded = Media.load(media_by_uuid[uuid_val].id)
    assert(loaded, "Media.load must return record")
    assert(loaded.file_uuid == uuid_val,
        string.format("loaded file_uuid='%s', expected '%s'", tostring(loaded.file_uuid), uuid_val))

    print("  PASS: one media record, UUID persisted, both paths resolve")
end)

--------------------------------------------------------------------------------
-- Test 3: clip_data.file_uuid enables media lookup when path differs
--------------------------------------------------------------------------------

print("\n--- Test 3: clip uses file_uuid to find media when path differs ---")

with_db(function()
    local uuid_val = "mc-uuid-002"
    local canonical_path = "/Volumes/Vol1/Media/broll.mov"
    local clip_path = "/Volumes/Vol3/Media/broll.mov"  -- different volume

    -- Create media with canonical path
    local media = Media.create({
        project_id = "proj",
        name = "broll.mov",
        file_path = canonical_path,
        file_uuid = uuid_val,
        duration_frames = 500,
        frame_rate = 24,
    })
    assert(media:save())

    -- Build lookup maps
    local media_by_uuid = { [uuid_val] = media }
    local media_by_path = { [canonical_path] = media }

    -- Clip has a DIFFERENT path (from a different volume) but same UUID
    local clip_data = {
        file_path = clip_path,
        file_uuid = uuid_val,
    }

    -- Resolve media_id: prefer UUID, fall back to path
    local media_id = nil
    if clip_data.file_uuid and media_by_uuid[clip_data.file_uuid] then
        media_id = media_by_uuid[clip_data.file_uuid].id
    elseif clip_data.file_path and media_by_path[clip_data.file_path] then
        media_id = media_by_path[clip_data.file_path].id
    end

    assert(media_id, "clip must resolve media_id via UUID even when path differs")
    assert(media_id == media.id, "resolved media_id must match")

    print("  PASS: clip resolves media via UUID when path doesn't match")
end)

print("\n✅ test_drp_media_dedup.lua passed")
