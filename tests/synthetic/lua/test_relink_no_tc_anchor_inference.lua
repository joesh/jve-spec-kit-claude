#!/usr/bin/env luajit
-- Regression: relinking the original project to media-managed trimmed
-- media must work for TC-less files (SFX WAVs, etc.) whose trim is
-- rebased to source 0.
--
-- Domain rule. A media file with NO embedded timecode anchor (no bext
-- time_reference, no tmcd) carries no absolute frame of its own. When
-- the project's clips reference it via absolute source coordinates
-- [source_in, source_out] and a trimmed candidate file has no TC
-- either, we have no way to read the trim's origin from the file. The
-- only signal we have is the project's own usage: if the trimmed file
-- is at least as long as the clips' used span (max(source_out) −
-- min(source_in)), we infer the trim's origin is min(source_in) —
-- exactly enough head was cut to put the earliest used frame at file
-- position 0. The inference fires only when the existing origin-0
-- anchor cannot contain the used range (it's strictly additive).
--
-- The inference is unverifiable from the file alone: if the user
-- actually trimmed past project usage, clips would play wrong content.
-- That risk is intrinsic to TC-less media and accepted by the user.

require("test_env")

local relinker = require("core.media_relinker")

print("=== Relinker: no-TC anchor inference for trimmed TC-less media ===")

local rules = {
    match_filename = true,
    match_timecode = true,
    accept_trimmed_media = true,
}

-- Shape mirrors anamnesis TC-0 SFX after Resolve media-manages: media
-- has start_tc=0 (DRP convention for TC-less), clips use a mid-file
-- range [40000..70000], trimmed file is exactly long enough to cover
-- the clips' used span.
local function tcless_media_info(extent_start, extent_end)
    return {
        media_id = "m_sfx",
        media_path = "/Volumes/Old/SFX/Smash.wav",
        media_name = "Smash.wav",
        media_start_tc_value = 0,
        media_start_tc_rate = 25,
        source_extent_start = extent_start,
        source_extent_end = extent_end,
        width = 0, height = 0,
        fps_num = 25, fps_den = 1,
    }
end

local candidate_index = { ["smash.wav"] = { "/local/Trimmed/Smash.wav" } }

local function probe_with_dur(dur)
    return function(path)
        if path ~= "/local/Trimmed/Smash.wav" then return nil end
        return {
            duration_frames = dur,
            fps_num = 25, fps_den = 1,
            width = 0, height = 0,
        }
    end
end

local function clip_loader_for(clips)
    return function(mid)
        if mid ~= "m_sfx" then return {} end
        return clips
    end
end

-- Case 1: trimmed file dur EXACTLY equal to used span.
-- Domain: media's clips reference absolute source frames 40000..70000
-- (a 30000-frame used span). Resolve trimmed the original to a 30000-
-- frame file. Since the file has no TC, the only consistent placement
-- is "trim's frame 0 = the earliest used frame of the original" —
-- i.e. the rebased file's TC origin in JVE's coordinate system must
-- equal the project's earliest used frame (40000). Playback computes
-- file_pos = source_in - file_tc_origin, so without this rebase every
-- read would land 40000 frames past EOF.
do
    local earliest_used = 40000
    local latest_used = 70000
    local mi = tcless_media_info(earliest_used, latest_used)
    local clips = {
        { clip_id = "c1", source_in = earliest_used, source_out = 55000,
          fps_num = 25, fps_den = 1 },
        { clip_id = "c2", source_in = 55000, source_out = latest_used,
          fps_num = 25, fps_den = 1 },
    }
    local file_dur = latest_used - earliest_used  -- exactly the used span
    local candidates = relinker.find_candidates_for_media(
        mi, candidate_index, rules, probe_with_dur(file_dur))
    assert(#candidates == 1,
        "TC-less candidate must survive match passes (no TC mismatch)")

    local results = relinker._classify_media(
        mi, candidates, clip_loader_for(clips))
    assert(#results.failed == 0, string.format(
        "TC-less trimmed file long enough for used span must relink, "
        .. "not fail (reason=%s)",
        results.failed[1] and tostring(results.failed[1].reason) or "?"))
    assert(#results.relinked == 1, string.format(
        "expected 1 clean relink, got %d", #results.relinked))
    local re = results.relinked[1]
    assert(re.new_path == "/local/Trimmed/Smash.wav", "wrong relink target")
    assert(not re.needs_split, string.format(
        "full-fit inferred relink must not split (got needs_split=%s)",
        tostring(re.needs_split)))
    assert(not re.coverage, string.format(
        "full-fit inferred relink must not carry coverage note (got %s)",
        tostring(re.coverage)))
    -- Persisted TC origin must equal the project's earliest used frame —
    -- that's the only value that makes file_pos = source_in - origin land
    -- the earliest clip's first frame at file byte 0.
    assert(re.probed_tc, "inference must emit probed_tc to rebase media_ref")
    assert(re.probed_tc.start_tc_value == earliest_used, string.format(
        "rebased TC origin must equal earliest used frame (%d), got %s",
        earliest_used, tostring(re.probed_tc.start_tc_value)))
    assert(re.probed_tc.start_tc_rate == mi.media_start_tc_rate, string.format(
        "rebased TC rate must equal media's stored rate (%s), got %s",
        tostring(mi.media_start_tc_rate),
        tostring(re.probed_tc.start_tc_rate)))
end

-- Case 2: trimmed file LONGER than used span (extra head/tail kept).
-- Used span = 30000; file dur = 50000. Inference still anchors at
-- min(source_in) = 40000, so file covers [40000..90000], comfortably
-- containing [40000..70000]. Same clean-relink shape as Case 1.
do
    local mi = tcless_media_info(40000, 70000)
    local clips = {
        { clip_id = "c1", source_in = 40000, source_out = 55000,
          fps_num = 25, fps_den = 1 },
        { clip_id = "c2", source_in = 55000, source_out = 70000,
          fps_num = 25, fps_den = 1 },
    }
    local candidates = relinker.find_candidates_for_media(
        mi, candidate_index, rules, probe_with_dur(50000))
    local results = relinker._classify_media(
        mi, candidates, clip_loader_for(clips))
    assert(#results.relinked == 1 and not results.relinked[1].needs_split,
        "file longer than used span still infers anchor at min(source_in)")
    assert(results.relinked[1].probed_tc
        and results.relinked[1].probed_tc.start_tc_value == 40000,
        "inferred anchor = min(source_in) regardless of extra headroom")
end

-- Case 3: trimmed file SHORTER than used span. Domain: project
-- references 30000 frames of original; trimmed file is only 20000.
-- No single placement of the file inside source space contains every
-- clip's range — at least one clip must read past EOF. Observable
-- outcome: the user gets a coverage report describing what the file
-- DOES cover (so the source viewer can show "found X, missing Yf"),
-- not a clean relink that lies about coverage.
do
    local earliest_used = 40000
    local latest_used = 70000
    local mi = tcless_media_info(earliest_used, latest_used)
    local clips = {
        { clip_id = "c1", source_in = earliest_used, source_out = 55000,
          fps_num = 25, fps_den = 1 },
        { clip_id = "c2", source_in = 55000, source_out = latest_used,
          fps_num = 25, fps_den = 1 },
    }
    local file_dur = (latest_used - earliest_used) - 10000  -- 10000 short
    local candidates = relinker.find_candidates_for_media(
        mi, candidate_index, rules, probe_with_dur(file_dur))
    local results = relinker._classify_media(
        mi, candidates, clip_loader_for(clips))
    assert(#results.relinked == 1, string.format(
        "shortfall must still produce a relink entry (so the user sees "
        .. "the file we found), got %d relinked / %d failed",
        #results.relinked, #results.failed))
    local re = results.relinked[1]
    assert(re.coverage, "shortfall relink must carry a coverage report "
        .. "describing the file's actual range — the user needs to know "
        .. "what's missing")
    -- The relink must not pretend the file covers the full used range.
    -- Either it carries a coverage note (file shorter than used span)
    -- or it's a split (some clips fit, others don't). A clean entry
    -- without either would be the buggy outcome the inference exists
    -- to prevent — and must not fire when the file can't actually cover.
    assert(re.coverage or re.needs_split,
        "shortfall must surface as partial coverage or split, never as "
        .. "a clean full relink")
end

-- Case 4: media has a real non-zero stored TC anchor (Case 3 of the
-- existing TC-less test). Inference must NOT fire — stored anchor
-- means we know the file's TC origin should match it, and a TC-less
-- candidate is an unverifiable identity match. Existing partial-
-- coverage path applies.
do
    local mi = tcless_media_info(90000, 90100)
    mi.media_start_tc_value = 90000  -- real stored anchor, not the 0 sentinel
    local clips = {
        { clip_id = "c_far", source_in = 90000, source_out = 90100,
          fps_num = 25, fps_den = 1 },
    }
    -- candidate filename match
    local far_index = { ["smash.wav"] = { "/local/Trimmed/Smash.wav" } }
    local candidates = relinker.find_candidates_for_media(
        mi, far_index, rules, probe_with_dur(275))
    local results = relinker._classify_media(
        mi, candidates, clip_loader_for(clips))
    -- Media has its own TC anchor (90000), so the matcher already knows
    -- where the file's content lives in source space — inference must
    -- not override that with a fabricated anchor. Observable: the
    -- relink reports the file's actual origin-0 range as coverage, NOT
    -- a clean full relink at 90000.
    assert(#results.relinked == 1, "stored-TC media: file still surfaces")
    local re = results.relinked[1]
    assert(re.coverage and re.coverage.covered_start_tc == 0,
        "coverage anchor stays at 0 when media has its own stored TC "
        .. "(inference must not invent a 90000 anchor here)")
    assert(re.probed_tc == nil or re.probed_tc.start_tc_value ~= 90000,
        "inference must not stamp a 90000 anchor when the candidate "
        .. "has no TC and the file's true origin is unknown")
end

-- Case 5: existing origin-0 anchor already covers everything → no inference
-- needed (file is long enough from origin 0). Must match existing clean-
-- relink shape (no probed_tc stamping, no coverage note). Guards against
-- the inference path inadvertently changing the already-working case.
do
    local mi = tcless_media_info(7, 253)
    local clips = {
        { clip_id = "c1", source_in = 35, source_out = 246,
          fps_num = 25, fps_den = 1 },
        { clip_id = "c2", source_in = 7, source_out = 253,
          fps_num = 25, fps_den = 1 },
    }
    local clean_index = { ["smash.wav"] = { "/local/Trimmed/Smash.wav" } }
    local candidates = relinker.find_candidates_for_media(
        mi, clean_index, rules, probe_with_dur(275))
    local results = relinker._classify_media(
        mi, candidates, clip_loader_for(clips))
    assert(#results.relinked == 1 and not results.relinked[1].needs_split,
        "origin-0 anchor already works for used range starting near 0")
    -- Inference must NOT stamp probed_tc at 7 here — the existing
    -- containment passed at origin 0; stamping would needlessly rewrite
    -- the media_ref. Inference activates only when origin 0 fails.
    local re = results.relinked[1]
    local inferred = re.probed_tc and re.probed_tc.start_tc_value == 7
    assert(not inferred,
        "inference must not fire when origin-0 containment already passes")
end

print("✅ test_relink_no_tc_anchor_inference.lua passed")
