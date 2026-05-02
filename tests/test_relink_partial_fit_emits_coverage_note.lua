#!/usr/bin/env luajit
-- Regression: when the relinker's partial-fit path picks a candidate that
-- accommodates SOME clips but not others, the resulting split entry must
-- carry coverage info so the original media row gets an offline_note
-- describing the candidate. Without it, clips stranded by the split (the
-- ones that didn't fit the candidate) keep the original media's path —
-- which is the broken offline path the relink was trying to repair —
-- and the source viewer surfaces "File not found" pointing at a path
-- the user hasn't seen since the original DRP import. The actionable
-- truth is "we found <candidate> in your search tree, but it doesn't
-- cover the clip's source range"; that needs to land on the original
-- media's offline_note.
--
-- Domain shape:
--   needs_split = true entry from try_partial_fit_relink MUST carry
--   coverage = { kind = "partial_coverage", candidate_path,
--                covered_start_tc, covered_end_tc, rate }
--   pointing at the same candidate the split is using. The relink_planner
--   already turns entry.coverage into media_offline_notes[media_id], and
--   RelinkClips writes that to media.offline_note — so the only missing
--   link was the relinker not populating coverage on the split entry.

require("test_env")

local relinker = require("core.media_relinker")

print("=== Relinker emits coverage on split entries (partial-fit path) ===")

-- Setup: candidate covers 100025..100150 (125 frames). Three clips:
--   c_fit         [100050..100100] → strictly inside coverage → fits
--   c_head_short  [100024..100050] → 1f BEFORE coverage start → doesn't fit
--   c_tail_short  [100100..100151] → 1f AFTER  coverage end   → doesn't fit
-- The 1-frame deficits exercise the boundary: a clip that misses by even
-- a single frame must surface the partial-coverage signal, otherwise the
-- relink silently lies about what's playable.
-- source_extent must encompass all three clips → 100024..100151. That
-- range fails extent containment (extends past both ends of coverage),
-- so the candidate enters the partial_fit list.
local media_info = {
    media_id = "m_split",
    media_path = "/Volumes/AnamBack4 Joe/Footage/A035.mov",
    media_name = "A035.mov",
    -- media's stored TC sits at the same instant as candidate's start so
    -- the trimmed-media TC offset path doesn't reject the candidate; the
    -- per-clip head/tail deficits are what we want to exercise here.
    media_start_tc_value = 100025,
    media_start_tc_rate = 25,
    source_extent_start = 100024,
    source_extent_end   = 100151,
    width = 1920, height = 1080,
    fps_num = 25, fps_den = 1,
}

local candidate_index = { ["a035.mov"] = { "/local/A035.mov" } }
local probe_fn = function(path)
    if path == "/local/A035.mov" then
        return {
            start_tc_value = 100025,
            start_tc_rate = 25,
            duration_frames = 125,       -- 100025..100150
            fps_num = 25, fps_den = 1,
            width = 1920, height = 1080,
        }
    end
end
local rules = {
    match_filename = true,
    match_timecode = true,
    accept_trimmed_media = true,
}

local candidates = relinker.find_candidates_for_media(
    media_info, candidate_index, rules, probe_fn)
assert(#candidates == 1, string.format(
    "expected 1 candidate, got %d", #candidates))

local clip_loader = function(mid)
    if mid ~= "m_split" then return {} end
    return {
        { clip_id = "c_fit",        source_in = 100050, source_out = 100100,
          fps_num = 25, fps_den = 1, clip_kind = "video" },
        { clip_id = "c_head_short", source_in = 100024, source_out = 100050,
          fps_num = 25, fps_den = 1, clip_kind = "video" },
        { clip_id = "c_tail_short", source_in = 100100, source_out = 100151,
          fps_num = 25, fps_den = 1, clip_kind = "video" },
    }
end

local results = relinker._classify_media(media_info, candidates, clip_loader)

assert(#results.relinked == 1, string.format(
    "expected 1 relinked entry (the partial-fit split), got %d",
    #results.relinked))
local re = results.relinked[1]
assert(re.media_id == "m_split", "relinked.media_id mismatch")
assert(re.needs_split == true, string.format(
    "expected needs_split=true (1 of 3 clips fits — head and tail miss "
    .. "by 1 frame each), got %s", tostring(re.needs_split)))
assert(re.split_clip_ids and #re.split_clip_ids == 1
    and re.split_clip_ids[1] == "c_fit",
    "split_clip_ids should be exactly [c_fit] — c_head_short and "
    .. "c_tail_short are 1f past coverage at each end")

-- The bug: pre-fix the split entry had no `coverage` field, so the
-- planner's media_offline_notes loop never wrote a note for m_split.
-- The stranded clips (c_head_short, c_tail_short) then rendered with
-- no note, the viewer fell through to the "File not found" path
-- against the original DRP volume path, and the user got no signal
-- that we DID find a real candidate.
assert(type(re.coverage) == "table", string.format(
    "REGRESSION: split entry must carry coverage info so the planner can "
    .. "attach an offline_note to the original media. Without it, clips "
    .. "stranded by the split (didn't fit the candidate) render as "
    .. "'File not found' against the original DRP path instead of "
    .. "'Found <candidate>, missing Xf coverage'. Got coverage=%s",
    type(re.coverage)))
assert(re.coverage.kind == "partial_coverage", string.format(
    "coverage.kind = %s", tostring(re.coverage.kind)))
assert(re.coverage.candidate_path == "/local/A035.mov", string.format(
    "coverage.candidate_path must point at the same file the split used "
    .. "(otherwise the offline_note describes a different file than the "
    .. "fitting clips relinked to). got %s",
    tostring(re.coverage.candidate_path)))
assert(re.coverage.covered_start_tc == 100025, string.format(
    "covered_start_tc = %s (probe start_tc=100025)",
    tostring(re.coverage.covered_start_tc)))
assert(re.coverage.covered_end_tc == 100150, string.format(
    "covered_end_tc = %s (start 100025 + duration 125 = 100150)",
    tostring(re.coverage.covered_end_tc)))
assert(re.coverage.rate == 25, string.format(
    "coverage.rate = %s (stored_rate)", tostring(re.coverage.rate)))

print("✅ test_relink_partial_fit_emits_coverage_note passed")
