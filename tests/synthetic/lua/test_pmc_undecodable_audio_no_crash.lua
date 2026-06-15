#!/usr/bin/env luajit
-- A pool audio clip whose TracksBA blob did not decode (encrypted / truncated)
-- must import as zero-duration media (later dropped), NOT crash the whole import.
--
-- Domain: opening a Resolve project must degrade gracefully on un-decodable
-- per-clip metadata (imported-data rule) — one bad audio blob in a 2000-clip
-- pool cannot abort the entire open. Full-pool import applies pool metadata to
-- EVERY pool clip, so this path is now reachable for audio clips with no
-- decoded duration.

require("test_env")
print("=== test_pmc_undecodable_audio_no_crash.lua ===")

local drp = require("importers.drp_importer")

-- A pool audio clip with NO audio_duration (its TracksBA blob didn't decode).
local pmc = {
    id = "aud-1",
    name = "FieldRec_undecodable.wav",
    clip_type = "audio",
    file_tc_seconds = 3600.0,
    -- audio_duration intentionally absent (blob did not decode)
    -- num_frames intentionally absent (audio, no video frames)
}
local entry = {
    file_uuid = pmc.id, name = pmc.name, file_path = pmc.name,
    duration = 0, alt_paths = {},
}

-- Must not raise.
local ok, err = pcall(drp._apply_pmc_metadata, entry, pmc)
assert(ok, "applying pool metadata to an undecodable audio clip must not crash: "
    .. tostring(err))

-- It stays zero-duration (so try_import_media_item drops it) and gains no
-- fabricated channel count.
assert(entry.duration == 0, string.format(
    "undecodable audio clip must stay zero-duration, got %s", tostring(entry.duration)))
assert(entry.audio_channels == nil, string.format(
    "undecodable audio clip must not get a fabricated channel count, got %s",
    tostring(entry.audio_channels)))

print("✅ test_pmc_undecodable_audio_no_crash.lua passed")
