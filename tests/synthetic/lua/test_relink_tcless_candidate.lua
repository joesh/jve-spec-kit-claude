#!/usr/bin/env luajit
-- Regression: a name-matched candidate file that carries NO embedded
-- timecode must relink when the clips' source ranges fit inside the
-- file played from origin zero.
--
-- Domain rule (2026-06-12, Joe): a media file without embedded TC has
-- TC origin 00:00:00:00 — that is exactly how the decoder treats it at
-- playback (file_pos = source_in - file_tc_origin, origin 0 when the
-- file has no TC). The matcher must therefore anchor TC-less candidates
-- at 0 and run the normal extent/containment checks, instead of
-- treating "no TC anchor" as "doesn't contain" and dropping the file.
--
-- Real-world shape (anamnesis-gold-timeline): "Anamnesis Title.mp4" is
-- a 275-frame 25fps render with no tmcd; the DRP import stored
-- start_tc_value=0 @25. The relinker found the file in the search tree,
-- demoted it to partial_fit because extent containment returned false
-- for the missing TC anchor, then both partial strategies (which also
-- required candidate TC) failed → "no matching candidate found".

require("test_env")

local relinker = require("core.media_relinker")

print("=== Relinker: TC-less candidates anchor at 00:00:00:00 ===")

local rules = {
    match_filename = true,
    match_timecode = true,
    accept_trimmed_media = true,
}

-- Mirrors the real project data: stored TC 0 @25 (DRP convention for a
-- TC-less render), clips spanning [7..253] in absolute source frames.
local function make_media_info()
    return {
        media_id = "m_title",
        media_path = "/Volumes/Old/VFX/Titles/Title.mp4",
        media_name = "Title.mp4",
        media_start_tc_value = 0,
        media_start_tc_rate = 25,
        source_extent_start = 7,
        source_extent_end = 253,
        width = 1920, height = 1080,
        fps_num = 25, fps_den = 1,
    }
end

local candidate_index = { ["title.mp4"] = { "/local/Assets/Title.mp4" } }

-- Probe of the found file: 25fps, no TC of any kind (no tmcd, no BWF).
local function probe_fn_with_duration(duration_frames)
    return function(path)
        if path == "/local/Assets/Title.mp4" then
            return {
                duration_frames = duration_frames,
                fps_num = 25, fps_den = 1,
                width = 3840, height = 2160,
            }
        end
    end
end

local clip_loader = function(mid)
    if mid ~= "m_title" then return {} end
    return {
        { clip_id = "c_video", source_in = 35, source_out = 246,
          fps_num = 25, fps_den = 1 },
        { clip_id = "c_audio", source_in = 7, source_out = 253,
          fps_num = 25, fps_den = 1 },
    }
end

-- Case 1: file is long enough for every clip (275 frames ⊇ [7..253])
-- → clean relink, no split, no coverage note.
do
    local media_info = make_media_info()
    local candidates = relinker.find_candidates_for_media(
        media_info, candidate_index, rules, probe_fn_with_duration(275))
    assert(#candidates == 1, string.format(
        "TC-less candidate must survive the match passes (no TC is not a "
        .. "mismatch), got %d candidates", #candidates))

    local results = relinker._classify_media(media_info, candidates, clip_loader)
    assert(#results.failed == 0, string.format(
        "REGRESSION: TC-less candidate covering all clips from origin 0 "
        .. "must relink, not fail (reason=%s)",
        results.failed[1] and tostring(results.failed[1].reason) or "?"))
    assert(#results.relinked == 1, string.format(
        "expected 1 relinked entry, got %d", #results.relinked))
    local re = results.relinked[1]
    assert(re.new_path == "/local/Assets/Title.mp4", "wrong relink target")
    assert(not re.needs_split, "full-fit relink must not split")
    assert(not re.coverage, "full-fit relink must not carry a coverage note")
end

-- Case 2: file shorter than some clips (200 frames). Played from origin
-- 0 it covers [0..200): c_video [35..150] would fit a 200f file only if
-- its range ends before 200 — use clips that straddle the boundary.
-- c_video [35..150] fits; c_audio [7..253] does not → split relink, and
-- the original media carries a coverage note anchored at 0.
do
    local media_info = make_media_info()
    local short_clip_loader = function(mid)
        if mid ~= "m_title" then return {} end
        return {
            { clip_id = "c_fits", source_in = 35, source_out = 150,
              fps_num = 25, fps_den = 1 },
            { clip_id = "c_long", source_in = 7, source_out = 253,
              fps_num = 25, fps_den = 1 },
        }
    end
    local candidates = relinker.find_candidates_for_media(
        media_info, candidate_index, rules, probe_fn_with_duration(200))
    assert(#candidates == 1, "short TC-less candidate must still be found")

    local results = relinker._classify_media(media_info, candidates, short_clip_loader)
    assert(#results.relinked == 1, string.format(
        "short TC-less candidate must relink via split (got %d relinked, "
        .. "%d failed)", #results.relinked, #results.failed))
    local re = results.relinked[1]
    assert(re.needs_split == true,
        "200f file can only serve the clip ending at 150 → needs_split")
    assert(re.split_clip_ids and #re.split_clip_ids == 1
        and re.split_clip_ids[1] == "c_fits",
        "only c_fits [35..150] fits inside [0..200)")
    assert(type(re.coverage) == "table",
        "split entry must carry coverage so stranded clips get a note")
    assert(re.coverage.covered_start_tc == 0, string.format(
        "TC-less file coverage starts at origin 0, got %s",
        tostring(re.coverage.covered_start_tc)))
    assert(re.coverage.covered_end_tc == 200, string.format(
        "coverage end = 0 + 200 frames, got %s",
        tostring(re.coverage.covered_end_tc)))
end

-- Case 3: clips reference absolute TC far beyond the file's origin-0
-- range (e.g. media stored with a high original TC, re-rendered without
-- TC). Nothing fits, but the file IS the user's media by name — promote
-- via partial coverage with an honest "covers 0..275" note so clips
-- render offline with a shortfall diagnostic instead of "file not found".
do
    local media_info = make_media_info()
    media_info.media_start_tc_value = 90000
    media_info.source_extent_start = 90000
    media_info.source_extent_end = 90100
    local far_clip_loader = function(mid)
        return {
            { clip_id = "c_far", source_in = 90000, source_out = 90100,
              fps_num = 25, fps_den = 1 },
        }
    end
    local candidates = relinker.find_candidates_for_media(
        media_info, candidate_index, rules, probe_fn_with_duration(275))
    assert(#candidates == 1, "candidate accepted on non-TC criteria")

    local results = relinker._classify_media(media_info, candidates, far_clip_loader)
    assert(#results.relinked == 1, string.format(
        "zero-overlap TC-less candidate promotes via partial coverage "
        .. "(got %d relinked, %d failed)",
        #results.relinked, #results.failed))
    local re = results.relinked[1]
    assert(re.strategy == "partial_coverage", string.format(
        "expected partial_coverage promotion, got strategy=%s",
        tostring(re.strategy)))
    assert(re.coverage and re.coverage.covered_start_tc == 0
        and re.coverage.covered_end_tc == 275, string.format(
        "coverage must describe the file's real origin-0 range, got [%s..%s]",
        tostring(re.coverage and re.coverage.covered_start_tc),
        tostring(re.coverage and re.coverage.covered_end_tc)))
end

print("✅ test_relink_tcless_candidate.lua passed")
