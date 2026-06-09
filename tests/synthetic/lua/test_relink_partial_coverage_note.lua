#!/usr/bin/env luajit
-- Regression: when the relinker finds a filename-matching candidate
-- whose TC/duration don't quite cover a clip's source range, it must
-- emit coverage info on the failed entry so downstream code can
-- persist a partial_coverage offline_note describing what we DID
-- find. Previously the failed entry was just {media_id, reason} and
-- the UI had nothing to show beyond "File not found".
--
-- Domain behavior:
--   A candidate with the same basename, valid probe, but clip range
--   extending past its duration → classify_media's failed[] entry
--   carries {coverage = {kind, candidate_path, covered_start_tc,
--   covered_end_tc, rate}}. The relink_planner passes this through
--   as a JSON-encoded offline_note keyed by media_id.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local relinker = require("core.media_relinker")

print("=== Relinker emits partial-coverage info for extent-rejected candidates ===")

-- Scenario: candidate's TC is offset from the media's stored TC, so it
-- enters the partial_fit path (not the clean-match path). Its coverage
-- also doesn't contain the clip's source range, so it fails per-clip
-- containment → fallthrough to failed[] with coverage info attached.
-- Numbers chosen so the offset is small+positive (within the trimmed-
-- media heuristic) but the clip[100000..100103] doesn't fit inside the
-- candidate extent [100020..100120].
local media_info = {
    media_id = "m1",
    media_path = "/Volumes/AnamBack4 Joe/Footage/A035.mov",
    media_name = "A035.mov",
    media_start_tc_value = 100000,
    media_start_tc_rate = 25,
    source_extent_start = 100000,
    source_extent_end = 100103,
    width = 1920, height = 1080,
    fps_num = 25, fps_den = 1,
}

local candidate_index = {
    ["a035.mov"] = { "/fixture/A035.mov" },
}

local probe_fn = function(path)
    if path == "/fixture/A035.mov" then
        return {
            start_tc_value = 100020,        -- 20 frames later than stored
            start_tc_rate = 25,
            duration_frames = 100,           -- covers 100020..100120
            fps_num = 25, fps_den = 1,
            width = 1920, height = 1080,
        }
    end
    return nil
end

local rules = {
    match_filename = true,
    match_timecode = true,
    accept_trimmed_media = true,
}

local candidates = relinker.find_candidates_for_media(
    media_info, candidate_index, rules, probe_fn)

assert(#candidates == 1,
    string.format("expected 1 candidate to pass find, got %d", #candidates))
assert(candidates[1].tc_mismatch == true, string.format(
    "candidate should be flagged tc_mismatch (accept_trimmed_media=true + " ..
    "offset=20). tc_mismatch=%s", tostring(candidates[1].tc_mismatch)))

-- classify_media is file-local; invoked directly through the _classify_media
-- test hook so we don't need a real on-disk search path.
local clip_loader = function(mid)
    if mid == "m1" then
        return {{
            clip_id = "c1",
            source_in = 100000,
            source_out = 100103,
            fps_num = 25, fps_den = 1,
            clip_kind = "video",
        }}
    end
    return {}
end

local results = relinker._classify_media(media_info, candidates, clip_loader)

-- Partial-coverage candidate is now a RELINK (moves media.file_path
-- to the real file on disk), not a failure. The coverage info rides
-- on the relinked entry so downstream can write the per-clip
-- offline_note for clips short of the coverage.
assert(#results.failed == 0, string.format(
    "partial candidate must not be a failure; got %d failed", #results.failed))
assert(#results.relinked == 1, string.format(
    "expected 1 relinked entry for the partial candidate, got %d",
    #results.relinked))
local re = results.relinked[1]
assert(re.media_id == "m1", "relinked entry media_id mismatch")
assert(re.new_path == "/fixture/A035.mov",
    "new_path must point to the real file on disk for Shift+F to work: "
    .. tostring(re.new_path))
assert(re.strategy == "partial_coverage",
    "strategy must be 'partial_coverage' so downstream code can recognize " ..
    "this as a partial-relink instead of a clean match: "
    .. tostring(re.strategy))
assert(type(re.coverage) == "table", string.format(
    "relinked entry must carry coverage info, got %s", type(re.coverage)))
assert(re.coverage.kind == "partial_coverage",
    "coverage.kind: " .. tostring(re.coverage.kind))
assert(re.coverage.candidate_path == "/fixture/A035.mov",
    "coverage.candidate_path: " .. tostring(re.coverage.candidate_path))
assert(re.coverage.covered_start_tc == 100020,
    "covered_start_tc: " .. tostring(re.coverage.covered_start_tc))
assert(re.coverage.covered_end_tc == 100120, string.format(
    "covered_end_tc: got %s (start+duration=100120)",
    tostring(re.coverage.covered_end_tc)))
assert(re.coverage.rate == 25,
    "rate should be stored_rate 25, got " .. tostring(re.coverage.rate))

print("✅ test_relink_partial_coverage_note.lua passed")
