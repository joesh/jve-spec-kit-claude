-- TDD: when a synced audio pool item is already in media_items keyed by
-- file_path only (seeded by Pass 1 pool scan, no file_uuid), resolve_synced_audio_linkage
-- must stamp file_uuid = audio_pmc.id on the existing entry so that importer_core
-- can register it in media_by_uuid, allowing build_synced_audio_map to find it.
--
-- Without the fix, build_synced_audio_map logs:
--   "synced audio pool_id <UUID> not in media_by_uuid"
-- and synced audio is silently skipped on mediaseq construction.

require("test_env")

local drp_importer = require("importers.drp_importer")
local resolve = drp_importer._resolve_synced_audio_linkage
assert(resolve, "drp_importer._resolve_synced_audio_linkage must be exported")

print("=== test_synced_audio_linkage_uuid_stamp.lua ===")

local BTAI_ID      = "btai-1111-0000-0000-0000-000000000001"
local AUDIO_PMC_ID = "pmc-audio-2222-0000-0000-0000-000000000002"
local VIDEO_PMC_ID = "pmc-video-3333-0000-0000-0000-000000000003"
local AUDIO_PATH   = "/Volumes/RUSHES/A001_001.wav"
local VIDEO_PATH   = "/Volumes/RUSHES/A001_C001.mov"

-- ── Helpers replicating drp_importer's internal media_get / media_put ────────

local function make_media_store()
    local media_items = {}
    local path_to_key = {}

    local function put(entry)
        local key = (entry.file_uuid and entry.file_uuid ~= "")
                    and entry.file_uuid or entry.file_path
        if not key or key == "" then return end
        media_items[key] = entry
        if entry.file_path and entry.file_path ~= "" then
            path_to_key[entry.file_path] = key
        end
        for alt in pairs(entry.alt_paths or {}) do
            path_to_key[alt] = key
        end
    end

    local function get(file_uuid, file_path)
        if file_uuid and file_uuid ~= "" and media_items[file_uuid] then
            return media_items[file_uuid]
        end
        if file_path and file_path ~= "" then
            local key = path_to_key[file_path]
            if key then return media_items[key] end
        end
        return nil
    end

    return media_items, put, get
end

-- ── Test: audio entry pre-seeded by path, video pmc uses CUSTOM ─────────────

local media_items, media_put, media_get = make_media_store()

-- Simulate Pass 1 (parse_media_pool): audio file is known by path, no UUID
local audio_entry = {
    name      = "A001_001.wav",
    file_path = AUDIO_PATH,
    file_uuid = nil,
    alt_paths = {},
}
media_put(audio_entry)  -- keyed by path since file_uuid is nil

-- Also seed the video entry by path
local video_entry = {
    name      = "A001_C001",
    file_path = VIDEO_PATH,
    file_uuid = nil,
    alt_paths = {},
}
media_put(video_entry)

-- master_clips: audio pmc owns the btai, video pmc references it via audio_refs
local audio_pmc = {
    id                    = AUDIO_PMC_ID,
    name                  = "A001_001.wav",
    file_path             = AUDIO_PATH,
    own_bt_audio_info_ids = { BTAI_ID },
    audio_channels        = 2,
}
local video_pmc = {
    id                    = VIDEO_PMC_ID,
    name                  = "A001_C001",
    file_path             = VIDEO_PATH,
    audio_source          = "AUDIO_SOURCE_CUSTOM",
    audio_refs            = { BTAI_ID },
    own_bt_audio_info_ids = {},
}

resolve({ video_pmc, audio_pmc }, media_get, media_put)

-- 1. audio_entry must now have file_uuid stamped
assert(audio_entry.file_uuid == AUDIO_PMC_ID, string.format(
    "audio_entry.file_uuid should be '%s', got '%s'\n"
    .. "  (path-keyed entry was not upgraded — build_synced_audio_map will miss it)",
    AUDIO_PMC_ID, tostring(audio_entry.file_uuid)))
print("  ✓ path-keyed audio entry gets file_uuid stamped after resolve")

-- 2. After stamping, importer_core can key it in media_by_uuid.
--    Simulate: iterate all media_items as importer_core does, build media_by_uuid.
local media_by_uuid = {}
for _, item in pairs(media_items) do
    if item.file_uuid and item.file_uuid ~= "" then
        media_by_uuid[item.file_uuid] = { id = "db-audio-id" }
    end
end
assert(media_by_uuid[AUDIO_PMC_ID] ~= nil,
    "media_by_uuid must contain the audio entry after UUID stamp — "
    .. "build_synced_audio_map needs this to map synced_audio_pool_ids → DB media ids")
print("  ✓ media_by_uuid finds audio entry by UUID after stamp")

-- 3. synced_audio_pool_ids must be set on the video entry
assert(video_entry.synced_audio_pool_ids ~= nil,
    "video_entry.synced_audio_pool_ids must be set")
assert(#video_entry.synced_audio_pool_ids == 1
    and video_entry.synced_audio_pool_ids[1] == AUDIO_PMC_ID, string.format(
    "synced_audio_pool_ids should be ['%s'], got %s",
    AUDIO_PMC_ID, tostring(video_entry.synced_audio_pool_ids and
        video_entry.synced_audio_pool_ids[1])))
print("  ✓ video entry has synced_audio_pool_ids = [AUDIO_PMC_ID]")

print("✅ test_synced_audio_linkage_uuid_stamp.lua passed")
