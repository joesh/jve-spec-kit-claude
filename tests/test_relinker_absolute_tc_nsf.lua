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

local function make_probe_fn(tc_map)
    return function(path) -- luacheck: ignore 212
        local entry = tc_map[path]
        if entry then return entry.value, entry.rate end
        return nil, nil
    end
end

local function make_media_probe_fn(media_map)
    return function(path) -- luacheck: ignore 212
        return media_map[path]
    end
end

--------------------------------------------------------------------------------
-- Test 1: Absolute TC containment — source_in IS absolute, no tc origin added
--------------------------------------------------------------------------------
print("\n--- Test 1: Containment with absolute TC source_in ---")
do
    -- Clip: source_in=89850 (absolute TC), source_out=89950
    -- Stored TC origin = 89750
    -- Candidate TC = 89800, duration=500 → covers [89800, 90300)
    -- Clip range [89850, 89950] fits inside [89800, 90300) → accepted
    local clip = {
        clip_id = "c1", media_id = "m1",
        source_in = 89850,   -- ABSOLUTE TC (not file-relative 100!)
        source_out = 89950,
        fps_num = 25, fps_den = 1,
        media_start_tc_value = 89750,
        media_start_tc_rate = 25,
        media_path = "/old/clip.mov",
        media_name = "clip.mov",
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
        ["/new/clip.mov"] = {value = 89800, rate = 25},
    })
    local media_probe = make_media_probe_fn({
        ["/new/clip.mov"] = {duration_frames = 500, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080},
    })

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 1, string.format(
        "absolute TC containment should pass, got %d candidates", #candidates))
    print("  ✓ absolute TC [89850,89950] fits in candidate [89800,90300)")
end

--------------------------------------------------------------------------------
-- Test 2: Absolute TC NOT contained — candidate too short
--------------------------------------------------------------------------------
print("\n--- Test 2: Absolute TC NOT contained ---")
do
    -- Clip: source_in=89850, source_out=89950 (absolute TC)
    -- Candidate: TC=89900, duration=20 → [89900, 89920)
    -- Clip starts at 89850 < 89900 → NOT contained
    local clip = {
        clip_id = "c2", media_id = "m2",
        source_in = 89850,
        source_out = 89950,
        fps_num = 25, fps_den = 1,
        media_start_tc_value = 89750,
        media_start_tc_rate = 25,
        media_path = "/old/clip.mov",
        media_name = "clip.mov",
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
        ["/new/clip.mov"] = {value = 89900, rate = 25},
    })
    local media_probe = make_media_probe_fn({
        ["/new/clip.mov"] = {duration_frames = 20, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080},
    })

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 0, string.format(
        "clip NOT contained: expected 0 candidates, got %d", #candidates))
    print("  ✓ absolute TC [89850,89950] not in candidate [89900,89920)")
end

--------------------------------------------------------------------------------
-- Test 3: TC offset adjustment with absolute TC
--------------------------------------------------------------------------------
print("\n--- Test 3: adjust_source_range with absolute TC ---")
do
    -- source_in=89850 (absolute TC), source_out=89950
    -- Offset = 50 (candidate starts 50 frames later)
    -- new_in = 89850 - 50 = 89800, new_out = 89950 - 50 = 89900
    local new_in, new_out = relinker.adjust_source_range(89850, 89950, 50, 25)
    assert(new_in == 89800, string.format("adjusted in: expected 89800, got %s", tostring(new_in)))
    assert(new_out == 89900, string.format("adjusted out: expected 89900, got %s", tostring(new_out)))
    print("  ✓ adjust_source_range: 89850-50=89800, 89950-50=89900")
end

--------------------------------------------------------------------------------
-- Test 4: TC offset that would make source_in negative → nil
--------------------------------------------------------------------------------
print("\n--- Test 4: Large offset makes source_in negative → nil ---")
do
    -- source_in=100 (small absolute TC from MST=0 file), offset=200
    -- new_in = 100 - 200 = -100 → nil
    local new_in, new_out = relinker.adjust_source_range(100, 200, 200, 25)
    assert(new_in == nil, "negative result should return nil")
    assert(new_out == nil, "negative result should return nil for out too")
    print("  ✓ offset causing negative → nil, nil")
end

print("\n✅ test_relinker_absolute_tc_nsf.lua passed")
