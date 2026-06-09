#!/usr/bin/env luajit
-- Regression: media_status.ensure_clip_status marks a clip offline
-- when its per-clip source range extends past the coverage recorded
-- in offline_note, even if the media file itself is online.
--
-- Rationale: "offline" is the union of two conditions — file missing
-- (media-level) OR content insufficient for this clip's source range
-- (per-clip). A partial-coverage relink moves media.file_path to a
-- real file on disk; some clips using that media fit within coverage
-- (play online), others extend past (render offline with a "short Nf"
-- suffix and partial-coverage offline frame). A pure media-level
-- offline check can't distinguish those two clips.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local media_status = require("core.media.media_status")
local json = require("dkjson")

print("=== media_status: per-clip shortfall → clip.offline ===")

-- A coverage note: file covers TC 100000..100100 at 25 fps.
local note_json = json.encode({
    kind = "partial_coverage",
    candidate_path = "/fixture/A001.mov",
    covered_start_tc = 100000,
    covered_end_tc   = 100100,
    rate = 25,
})

-- Prime status_cache: each case uses a unique path so cache entries
-- don't collide across checks. Module has no public reset helper,
-- so we just work with distinct paths.
local P_A = "/fixture/test_shortfall_A.mov"
local P_B = "/fixture/test_shortfall_B.mov"
local P_C = "/fixture/test_shortfall_C.mov"
local P_MISSING = "/missing/test_shortfall_M.mov"
local P_D = "/fixture/test_shortfall_D.mov"

media_status.update_from_tmb(P_A, false, nil)
media_status.update_from_tmb(P_B, false, nil)
media_status.update_from_tmb(P_C, false, nil)
media_status.update_from_tmb(P_MISSING, true, "FileNotFound")
media_status.update_from_tmb(P_D, false, nil)

-- Clip A: fully within coverage → online.
do
    local clip = {
        media_path = P_A,
        source_in = 100010, source_out = 100090,
        offline_note = note_json,
    }
    media_status.ensure_clip_status(clip)
    assert(clip.offline == false, string.format(
        "clip fully within coverage must stay online, got offline=%s",
        tostring(clip.offline)))
end

-- Clip B: source_out extends past coverage → offline (tail shortfall).
do
    local clip = {
        media_path = P_B,
        source_in = 100000, source_out = 100105,
        offline_note = note_json,
    }
    media_status.ensure_clip_status(clip)
    assert(clip.offline == true, string.format(
        "clip extending past coverage must render offline, got offline=%s",
        tostring(clip.offline)))
    assert(clip.error_code == "InsufficientCoverage", string.format(
        "error_code must mark coverage-insufficiency: got %s",
        tostring(clip.error_code)))
end

-- Clip C: source_in before coverage → offline (head shortfall).
do
    local clip = {
        media_path = P_C,
        source_in = 99980, source_out = 100050,
        offline_note = note_json,
    }
    media_status.ensure_clip_status(clip)
    assert(clip.offline == true, "head-short clip must render offline")
end

-- Missing-file case: file-level offline wins regardless of coverage.
do
    local clip = {
        media_path = P_MISSING,
        source_in = 0, source_out = 100,
    }
    media_status.ensure_clip_status(clip)
    assert(clip.offline == true, "missing-file clip must be offline")
    assert(clip.error_code == "FileNotFound",
        "missing file retains FileNotFound error code")
end

-- Clip with offline_note BUT no source range → don't crash; fall
-- through to pure media-level status (online here).
do
    local clip = {
        media_path = P_D,
        offline_note = note_json,
        -- no source_in/source_out
    }
    media_status.ensure_clip_status(clip)
    assert(clip.offline == false,
        "no-source-range clip with note falls through to media-level")
end

print("✅ test_media_status_clip_shortfall.lua passed")
