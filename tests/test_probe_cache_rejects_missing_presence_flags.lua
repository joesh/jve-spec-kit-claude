#!/usr/bin/env luajit
-- Regression: probe cache entries missing the has_duration /
-- has_video_tc_origin / has_audio_tc_origin presence flags must be
-- treated as misses (re-probed), not served back to relinker code
-- that gates duration_frames on has_duration.
--
-- Root cause of the TSO 2026-04-21 relink regression: c2b2b505 added
-- those presence flags to MediaFileInfo but did not bump CACHE_VERSION.
-- The pre-c2b2b505 cache at ~/.jve/probe_cache.json loaded successfully
-- (version matched), but entries had duration_us without has_duration.
-- probe_result_from_emp_info at media_relinker.lua:163 requires
-- has_duration to populate duration_frames. Result: cand_dur=0,
-- containment check [X,X] vs [X, X+N] always failed — 477 of 562
-- media appeared offline post-relink despite cache hits for all.
--
-- Domain behavior (not implementation):
--   A cache document from before presence-flag support must not leak
--   stale-shape info to the relinker. Either the version check
--   rejects the whole doc, or individual entries missing required
--   flags are classified as misses and re-probed.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local probe_cache = require("core.media_probe_cache")

print("=== probe cache must reject pre-presence-flags entries ===")

-- Fabricate the "legacy" cache entry shape as seen in the real
-- ~/.jve/probe_cache.json from the regression scene: duration_us is
-- present, but has_duration / has_video_tc_origin / has_audio_tc_origin
-- are missing entirely (not false — missing keys).
local legacy_entry_info = {
    path = "/fixture/Day 7/A020_10241200_C026.mov",
    width = 2048, height = 1152,
    has_video = true, has_audio = true,
    -- The three presence flags that c2b2b505 added are absent below.
    -- A newer probe would include has_duration = true,
    -- has_video_tc_origin = true, has_audio_tc_origin = false.
    duration_us = 9280000,
    first_frame_tc = 1081133,
    first_sample_tc = 0,
    fps_num = 25, fps_den = 1,
    audio_sample_rate = 48000, audio_channels = 2,
    par_num = 1, par_den = 1,
    is_vfr = false, rotation = 0,
    start_tc = 1081133,
}

local entries = {
    [legacy_entry_info.path] = {
        mtime = 1773473078, size = 367539672,
        info = legacy_entry_info,
    },
}

-- Stats (what qt_file_stat_batch would return) match the cache's
-- mtime/size exactly — so the mtime/size freshness test ALONE would
-- report a hit. The version/shape check must catch this.
local stats = {
    [legacy_entry_info.path] = { mtime = 1773473078, size = 367539672 },
}

-- ----------------------------------------------------------------------
-- Check 1: classify_paths must return this as a MISS (re-probe), not a
-- hit. Before the fix, freshness-only check → hit → stale info leaks.
-- ----------------------------------------------------------------------
print("Check 1: legacy-shape entry is classified as miss")
local result = probe_cache._classify_paths(
    {legacy_entry_info.path}, entries, stats)
assert(result.hit_count == 0, string.format(
    "legacy entry (no has_duration / has_*_tc_origin) must not be a hit, " ..
    "got hit_count=%d. The cache leaks pre-c2b2b505 shape to the relinker.",
    result.hit_count))
assert(#result.miss_paths == 1,
    "legacy entry must be in miss_paths for re-probe")
assert(result.miss_paths[1] == legacy_entry_info.path,
    "miss_paths must name the legacy entry")

-- ----------------------------------------------------------------------
-- Check 2: a properly-shaped entry (all presence flags present) is a
-- hit under the same stats. Proves the rejection is shape-targeted,
-- not overly broad.
-- ----------------------------------------------------------------------
print("Check 2: fresh-shape entry is still a hit")
local fresh_entry_info = {}
for k, v in pairs(legacy_entry_info) do fresh_entry_info[k] = v end
fresh_entry_info.has_duration = true
fresh_entry_info.has_video_tc_origin = true
fresh_entry_info.has_audio_tc_origin = false

local fresh_entries = {
    [fresh_entry_info.path] = {
        mtime = 1773473078, size = 367539672,
        info = fresh_entry_info,
    },
}
local fresh_result = probe_cache._classify_paths(
    {fresh_entry_info.path}, fresh_entries, stats)
assert(fresh_result.hit_count == 1, string.format(
    "fresh-shape entry should hit, got hit_count=%d", fresh_result.hit_count))

print("✅ test_probe_cache_rejects_missing_presence_flags.lua passed")
