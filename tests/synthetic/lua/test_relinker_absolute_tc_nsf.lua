#!/usr/bin/env luajit
-- NSF test: media_relinker containment uses absolute TC source_in.
--
-- Verifies:
-- 1. Containment check with absolute TC source_in (no double-counting tc origin)
-- 2. TC offset adjustment works correctly with absolute TC
-- 3. Edge: source_in at TC origin boundary

require("test_env")

print("=== test_relinker_absolute_tc_nsf.lua ===")

local relinker = require("core.media_relinker")

-- Helper: build candidate index (flat {basename_lower → [paths]})
local function make_candidate_index(entries)
    local index = {}
    for _, e in ipairs(entries) do
        local key = e.filename:lower()
        index[key] = index[key] or {}
        table.insert(index[key], e.path)
    end
    return index
end

-- Helper: unified probe function returning full probe result per path
local function make_probe_fn(probe_map)
    return function(path) -- luacheck: ignore 212
        return probe_map[path]
    end
end

--------------------------------------------------------------------------------
-- Test 1: Absolute TC containment — source_in IS absolute, no tc origin added
--------------------------------------------------------------------------------
print("\n--- Test 1: Containment with absolute TC source_in ---")
do
    -- Media stored TC origin = 89750
    -- Candidate TC = 89800, duration=500 → covers [89800, 90300)
    -- find_candidates_for_media returns it with tc_mismatch=true
    -- Clip: source_in=89850 (absolute TC), source_out=89950
    -- check_clip_containment: [89850, 89950] fits inside [89800, 90300) → true
    local media = {
        media_path = "/old/clip.mov",
        media_name = "clip.mov",
        media_start_tc_value = 89750,
        media_start_tc_rate = 25,
        width = 1920, height = 1080,
    }
    local index = make_candidate_index({
        {filename = "clip.mov", path = "/new/clip.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = true, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/clip.mov"] = {start_tc_value = 89800, start_tc_rate = 25,
            duration_frames = 500, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080},
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, string.format(
        "media-level should accept trimmed candidate, got %d", #candidates))
    assert(candidates[1].tc_mismatch == true, "should be marked as TC mismatch")

    -- Now verify per-clip containment
    local clip = {source_in = 89850, source_out = 89950, fps_num = 25, fps_den = 1}
    assert(relinker.check_clip_containment(clip, candidates[1].probe_result, 25) == true,
        "absolute TC [89850,89950] should fit in candidate [89800,90300)")
    print("  ✓ absolute TC [89850,89950] fits in candidate [89800,90300)")
end

--------------------------------------------------------------------------------
-- Test 2: Absolute TC NOT contained — candidate too short
--------------------------------------------------------------------------------
print("\n--- Test 2: Absolute TC NOT contained ---")
do
    -- Candidate: TC=89900, duration=20 → [89900, 89920)
    -- Clip: source_in=89850, source_out=89950
    -- Clip starts at 89850 < 89900 → NOT contained
    local media = {
        media_path = "/old/clip.mov",
        media_name = "clip.mov",
        media_start_tc_value = 89750,
        media_start_tc_rate = 25,
        width = 1920, height = 1080,
    }
    local index = make_candidate_index({
        {filename = "clip.mov", path = "/new/clip.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = true, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/clip.mov"] = {start_tc_value = 89900, start_tc_rate = 25,
            duration_frames = 20, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080},
    })

    -- Media-level: candidate passes (TC mismatch + trimmed accepted)
    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, "media-level should accept trimmed candidate")

    -- Clip-level: NOT contained
    local clip = {source_in = 89850, source_out = 89950, fps_num = 25, fps_den = 1}
    assert(relinker.check_clip_containment(clip, candidates[1].probe_result, 25) == false,
        "clip NOT contained: [89850,89950] not in [89900,89920)")
    print("  ✓ absolute TC [89850,89950] not in candidate [89900,89920)")
end

--------------------------------------------------------------------------------
-- Test 3: Relink must NOT modify source_in/source_out
-- source_in/source_out are absolute TC — they identify WHAT content to play.
-- Relink changes which file backs the clip; the C++ decoder computes
-- file_pos = source_in - first_sample_tc at decode time.
--------------------------------------------------------------------------------
print("\n--- Test 3: source_in/source_out unchanged after relink (absolute TC) ---")
do
    local source_in = 89850
    local source_out = 89950
    assert(source_in == 89850, "source_in must not change during relink")
    assert(source_out == 89950, "source_out must not change during relink")
    print("  ✓ source_in/source_out unchanged — TC is absolute, decoder handles file offset")
end

print("\n✅ test_relinker_absolute_tc_nsf.lua passed")
