-- Domain behavior: a camera clip that Resolve auto-synced attaches ONLY the
-- audio Resolve actually selected — not every candidate it analyzed.
--
-- When Resolve's "Auto Sync Audio" runs, the camera clip's FieldsBlob records
-- the whole ANALYSIS: every overlapping sound-roll it evaluated, each with its
-- own computed SampleOffset. Only ONE of those is the SELECTED synced audio
-- (the one shown in the Media Pool's "Synced Audio" column). Resolve serializes
-- the selected source LAST among the external references — its channels are the
-- per-group terminators, so the selected source's final channel is the last
-- external MediaRef before the camera's own embedded scratch (which always
-- trails). Verified against the anamnesis corpus: the 4 clips whose blobs list
-- multiple candidates (C033→290-T001, C031→342-T001, C034→290-T002,
-- C017→S028-T003) each match Resolve's Synced Audio column under this rule,
-- and all 382 single-candidate clips are trivially consistent.
--
-- The bug this guards: the importer attached EVERY external candidate as synced
-- audio, so an auto-synced camera clip grew 5–8 audio tracks from unrelated
-- sound rolls — wrong/duplicate audio on playback, and (because each candidate
-- carried an offset pointing outside its own media-managed trim) a cascade of
-- false "media too short" relink failures.

require("test_env")

local drp_importer = require("importers.drp_importer")
local resolve = assert(drp_importer._resolve_synced_audio_linkage,
    "drp_importer._resolve_synced_audio_linkage must be exported")

print("=== test_drp_synced_audio_picks_selected.lua ===")

-- BtAudioInfo DbIds (one per source; repeated once per channel in audio_refs).
local BTAI_CAND_A = "btai-cand-a-0000-0000-0000-000000000a01"
local BTAI_CAND_B = "btai-cand-b-0000-0000-0000-000000000b01"
local BTAI_CHOSEN = "btai-chosen-0000-0000-0000-0000000c0001"
local BTAI_SCRATCH = "btai-scratch-000-0000-0000-00000000d001"

local PMC_CAND_A = "pmc-cand-a-1111-1111-1111-111111110a01"
local PMC_CAND_B = "pmc-cand-b-2222-2222-2222-222222220b01"
local PMC_CHOSEN = "pmc-chosen-3333-3333-3333-3333333c0001"
local VIDEO_PMC  = "pmc-video-4444-4444-4444-444444440001"

-- Wire order mirrors the real analysis layout: candidates appear in contiguous
-- channel runs; the SELECTED source is interleaved and its last channel sits
-- immediately before the camera scratch. candidate A has MORE channels and
-- comes FIRST, so neither "most channels" nor "first" can accidentally pass.
--   idx: 1  2  3   4       5  6   7        8        9
--        A  A  A   CHOSEN  B  B   CHOSEN   SCRATCH  SCRATCH
local audio_refs = {
    BTAI_CAND_A, BTAI_CAND_A, BTAI_CAND_A,
    BTAI_CHOSEN,
    BTAI_CAND_B, BTAI_CAND_B,
    BTAI_CHOSEN,
    BTAI_SCRATCH, BTAI_SCRATCH,
}
-- Per-channel SampleOffsets, index-aligned with audio_refs. Distinct per source
-- so a leaked candidate would be detectable in offsets_by_pool.
local offsets = { 111, 111, 111, 7000, 222, 222, 7001, 0, 0 }

local video_pmc = {
    id = VIDEO_PMC, name = "CAM_C001", file_path = "/V/CAM_C001.mov",
    audio_source = "AUDIO_SOURCE_CUSTOM",
    audio_refs = audio_refs,
    audio_ref_sample_offsets = offsets,
    own_bt_audio_info_ids = { BTAI_SCRATCH },
}
local function audio_pmc(id, btai, name, nch)
    return { id = id, name = name, file_path = "/V/" .. name,
             own_bt_audio_info_ids = { btai }, audio_channels = nch }
end

local master_clips = {
    video_pmc,
    audio_pmc(PMC_CAND_A, BTAI_CAND_A, "candA.wav", 3),
    audio_pmc(PMC_CAND_B, BTAI_CAND_B, "candB.wav", 2),
    audio_pmc(PMC_CHOSEN, BTAI_CHOSEN, "chosen.wav", 2),
}

-- Minimal media store mirroring importer_core's media_get / media_put.
local media_items, path_to_key = {}, {}
local function media_put(entry)
    local key = (entry.file_uuid and entry.file_uuid ~= "") and entry.file_uuid or entry.file_path
    if not key or key == "" then return end
    media_items[key] = entry
    if entry.file_path and entry.file_path ~= "" then path_to_key[entry.file_path] = key end
end
local function media_get(file_uuid, file_path)
    if file_uuid and file_uuid ~= "" and media_items[file_uuid] then return media_items[file_uuid] end
    if file_path and file_path ~= "" and path_to_key[file_path] then return media_items[path_to_key[file_path]] end
    return nil
end
-- Seed the video + chosen audio entries (path-keyed, as Pass 1 would).
media_put({ name = "CAM_C001", file_path = "/V/CAM_C001.mov" })
media_put({ name = "chosen.wav", file_path = "/V/chosen.wav" })

resolve(master_clips, media_get, media_put)

local video_entry = media_get(VIDEO_PMC, "/V/CAM_C001.mov")
local ids = video_entry.synced_audio_pool_ids
assert(ids, "video entry must have synced_audio_pool_ids set")
assert(#ids == 1, string.format(
    "auto-synced clip must attach exactly ONE selected sync, got %d: %s",
    #ids, table.concat(ids, ", ")))
assert(ids[1] == PMC_CHOSEN, string.format(
    "selected sync must be the last external source (chosen.wav / %s), got %s",
    PMC_CHOSEN, ids[1]))

-- Candidates must NOT have leaked into the offset map.
local by_pool = video_entry.synced_audio_offsets_by_pool_id
assert(by_pool[PMC_CHOSEN], "chosen pool must carry its channel offsets")
assert(not by_pool[PMC_CAND_A] and not by_pool[PMC_CAND_B],
    "rejected candidates must not appear in synced_audio_offsets_by_pool_id")
-- The chosen source's two channels carry its own offsets (not a candidate's).
assert(#by_pool[PMC_CHOSEN] == 2, string.format(
    "chosen must have 2 channel offsets, got %d", #by_pool[PMC_CHOSEN]))
assert(by_pool[PMC_CHOSEN][1] == 7000 and by_pool[PMC_CHOSEN][2] == 7001,
    "chosen channel offsets must be its own values (7000, 7001)")

print("  ✓ only the selected sync (last external) is attached; candidates rejected")
print("✅ test_drp_synced_audio_picks_selected.lua passed")
