#!/usr/bin/env luajit
-- Failure diagnostics: when a media fails to relink, the failed entry
-- must say WHY in user-readable terms, and must distinguish:
--   kind = "not_found"  — no file with the media's name anywhere in the
--                         search tree (user: go find the file)
--   kind = "rejected"   — file(s) with the right name WERE found but a
--                         matching rule rejected them, with the concrete
--                         mismatch spelled out (user: fix rules or accept
--                         the file is different)
-- Timecode values render as HH:MM:SS:FF (never raw frame numbers);
-- resolutions as WxH; frame rates in fps.
--
-- Pre-change, every such failure surfaced as the catch-all
-- "no matching candidate found", which lumps "file missing" with
-- "file present but rejected" — the user can't act on it.

require("test_env")

local relinker = require("core.media_relinker")

print("=== Relinker: failure reasons are specific and actionable ===")

local function base_media_info()
    return {
        media_id = "m1",
        media_path = "/Volumes/Old/Footage/A035.mov",
        media_name = "A035.mov",
        media_start_tc_value = 100025,   -- 01:06:41:00 @25
        media_start_tc_rate = 25,
        source_extent_start = 100025,
        source_extent_end = 100125,
        width = 1920, height = 1080,
        fps_num = 25, fps_den = 1,
    }
end

-- Case 1: nothing with this basename in the search tree → not_found.
do
    local media_info = base_media_info()
    local candidates, rejected = relinker.find_candidates_for_media(
        media_info, {}, { match_filename = true, match_timecode = true },
        function() return nil end)
    assert(#candidates == 0 and #rejected == 0)

    local results = relinker._classify_media(media_info, candidates, nil, rejected)
    assert(#results.failed == 1, "media with no candidates must fail")
    local f = results.failed[1]
    assert(f.kind == "not_found", string.format(
        "missing file must classify as not_found, got kind=%s",
        tostring(f.kind)))
    assert(type(f.reason) == "string" and #f.reason > 0,
        "not_found entries still carry a human-readable reason")
end

-- Case 2: file found, timecode mismatch, trimmed-media acceptance OFF →
-- rejected, reason carries both TCs as HH:MM:SS:FF.
-- Candidate TC 200000 @25 = 02:13:20:00; stored 100025 @25 = 01:06:41:00.
do
    local media_info = base_media_info()
    local index = { ["a035.mov"] = { "/local/A035.mov" } }
    local probe = function(path)
        return {
            start_tc_value = 200000, start_tc_rate = 25,
            duration_frames = 500, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080,
        }
    end
    local rules = { match_filename = true, match_timecode = true,
                    accept_trimmed_media = false }
    local candidates, rejected = relinker.find_candidates_for_media(
        media_info, index, rules, probe)
    assert(#candidates == 0, "TC-mismatched candidate must not pass")
    assert(#rejected == 1, string.format(
        "rejected candidate must be reported, got %d", #rejected))

    local results = relinker._classify_media(media_info, candidates, nil, rejected)
    assert(#results.failed == 1)
    local f = results.failed[1]
    assert(f.kind == "rejected", string.format(
        "found-but-rejected must classify as rejected, got kind=%s",
        tostring(f.kind)))
    assert(f.reason:find("02:13:20:00", 1, true), string.format(
        "reason must show the file's TC as HH:MM:SS:FF: %s", f.reason))
    assert(f.reason:find("01:06:41:00", 1, true), string.format(
        "reason must show the stored TC as HH:MM:SS:FF: %s", f.reason))
    assert(f.reason:find("A035.mov", 1, true), string.format(
        "reason must name the file it found: %s", f.reason))
end

-- Case 3: resolution rule on, file is a UHD re-render of an HD record →
-- rejected, reason carries both resolutions.
do
    local media_info = base_media_info()
    local index = { ["a035.mov"] = { "/local/A035.mov" } }
    local probe = function(path)
        return {
            start_tc_value = 100025, start_tc_rate = 25,
            duration_frames = 500, fps_num = 25, fps_den = 1,
            width = 3840, height = 2160,
        }
    end
    local rules = { match_filename = true, match_timecode = true,
                    match_resolution = true }
    local candidates, rejected = relinker.find_candidates_for_media(
        media_info, index, rules, probe)
    assert(#candidates == 0 and #rejected == 1)

    local results = relinker._classify_media(media_info, candidates, nil, rejected)
    local f = results.failed[1]
    assert(f.kind == "rejected")
    assert(f.reason:find("3840x2160", 1, true)
        and f.reason:find("1920x1080", 1, true), string.format(
        "resolution rejection must show both resolutions: %s", f.reason))
end

-- Case 4: frame-rate rule on, 29.97fps file against a 25fps record →
-- rejected, reason carries both rates in fps.
do
    local media_info = base_media_info()
    local index = { ["a035.mov"] = { "/local/A035.mov" } }
    local probe = function(path)
        return {
            start_tc_value = 100025, start_tc_rate = 25,
            duration_frames = 500, fps_num = 30000, fps_den = 1001,
            width = 1920, height = 1080,
        }
    end
    local rules = { match_filename = true, match_timecode = true,
                    match_frame_rate = true }
    local candidates, rejected = relinker.find_candidates_for_media(
        media_info, index, rules, probe)
    assert(#candidates == 0 and #rejected == 1)

    local results = relinker._classify_media(media_info, candidates, nil, rejected)
    local f = results.failed[1]
    assert(f.kind == "rejected")
    assert(f.reason:find("29.97", 1, true), string.format(
        "fps rejection must show the file's rate: %s", f.reason))
    assert(f.reason:find("25", 1, true), string.format(
        "fps rejection must show the stored rate: %s", f.reason))
end

-- Case 5: trimmed-media path with an implausible TC offset (candidate
-- starts BEFORE the stored original TC — not a trim of the original).
-- The candidate silently vanished from both viable and partial lists
-- pre-change; it must surface as rejected with the TC mismatch.
do
    local media_info = base_media_info()
    local index = { ["a035.mov"] = { "/local/A035.mov" } }
    local probe = function(path)
        return {
            -- 50000 @25 = 00:33:20:00, before stored 01:06:41:00, and the
            -- 500-frame extent can't contain the clips → dropped by the
            -- plausible-trim window.
            start_tc_value = 50000, start_tc_rate = 25,
            duration_frames = 500, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080,
        }
    end
    local rules = { match_filename = true, match_timecode = true,
                    accept_trimmed_media = true }
    local candidates, rejected = relinker.find_candidates_for_media(
        media_info, index, rules, probe)
    assert(#candidates == 1,
        "trimmed-media acceptance keeps the candidate in play")

    local results = relinker._classify_media(media_info, candidates, nil, rejected)
    assert(#results.failed == 1, string.format(
        "implausible-trim candidate must fail (got %d relinked)",
        #results.relinked))
    local f = results.failed[1]
    assert(f.kind == "rejected", string.format(
        "file was found — must classify rejected, got %s", tostring(f.kind)))
    assert(f.reason:find("00:33:20:00", 1, true)
        and f.reason:find("01:06:41:00", 1, true), string.format(
        "implausible-trim rejection must show both TCs: %s", f.reason))
end

print("✅ test_relink_failure_reasons.lua passed")
