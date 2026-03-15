#!/usr/bin/env luajit
--- T005: Candidate filtering — find_candidates_for_clip
-- Tests find_candidates_for_clip() which doesn't exist yet — MUST FAIL.
require("test_env")

print("=== test_candidate_filtering.lua ===")

local relinker = require("core.media_relinker")

-- Helper: build a clip_info struct matching the contract
local function make_clip_info(overrides)
    local defaults = {
        clip_id = "clip-001",
        media_id = "media-001",
        source_in = 100,
        source_out = 200,
        fps_num = 25,
        fps_den = 1,
        media_start_tc_value = 89750, -- 00:59:50:00 @ 25fps
        media_start_tc_rate = 25,
        media_path = "/offline/A026_C007.mov",
        media_name = "A026_C007.mov",
        width = 1920,
        height = 1080,
        clip_kind = "timeline",
    }
    if overrides then
        for k, v in pairs(overrides) do defaults[k] = v end
    end
    return defaults
end

-- Helper: build a candidate entry
-- probe_fn simulates ffprobe results for each candidate path
local function make_candidate_index(entries)
    local index = {}
    for _, e in ipairs(entries) do
        local key = e.filename:lower()
        index[key] = index[key] or {}
        table.insert(index[key], e.path)
    end
    return index
end

-- Helper: probe function that returns preset TC values per path
local function make_probe_fn(tc_map)
    return function(path)
        local entry = tc_map[path]
        if not entry then return nil, nil end
        return entry.value, entry.rate
    end
end

-- Helper: probe function that returns preset media info per path
local function make_media_probe_fn(info_map)
    return function(path)
        return info_map[path]
    end
end

---------------------------------------------------------------------------------
-- find_candidates_for_clip(clip_info, candidate_index, matching_rules, probe_tc_fn, probe_media_fn)
-- Returns array of {path, start_tc_value, start_tc_rate, ...} for candidates
-- that pass ALL enabled criteria.
---------------------------------------------------------------------------------

print("\n--- filename-only matching ---")

-- Test 1: Filename match finds candidate
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = false,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({})
    local media_probe = make_media_probe_fn({})

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 1, string.format("expected 1 candidate, got %d", #candidates))
    assert(candidates[1].path == "/new/A026_C007.mov", "wrong path")
    print("  ✓ filename-only match returns candidate")
end

-- Test 2: Filename mismatch → no candidates
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "B001_C001.mov", path = "/new/B001_C001.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = false,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({})
    local media_probe = make_media_probe_fn({})

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 0, "filename mismatch: expected 0 candidates")
    print("  ✓ filename mismatch → 0 candidates")
end

print("\n--- timecode matching ---")

-- Test 3: TC match — candidate TC matches stored TC
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {value = 89750, rate = 25},
    })
    local media_probe = make_media_probe_fn({})

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 1, string.format("TC match: expected 1, got %d", #candidates))
    print("  ✓ matching TC → candidate accepted")
end

-- Test 4: TC mismatch, accept_trimmed_media OFF → rejected
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {value = 90000, rate = 25},  -- different TC
    })
    local media_probe = make_media_probe_fn({})

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 0, "TC mismatch without accept_trimmed: expected 0")
    print("  ✓ TC mismatch + accept_trimmed OFF → rejected")
end

-- Test 5: TC mismatch, accept_trimmed_media ON → accepted with TC containment check
-- Clip needs frames 100-200 relative to stored TC 89750.
-- Absolute clip range: 89850-89950 @ 25fps.
-- Candidate starts at 89800 with 500 frames duration → contains 89850-89950 → OK.
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = true, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {value = 89800, rate = 25},
    })
    local media_probe = make_media_probe_fn({
        ["/new/A026_C007.mov"] = {duration_frames = 500, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080},
    })

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 1, string.format("trimmed accepted: expected 1, got %d", #candidates))
    print("  ✓ TC mismatch + accept_trimmed ON + containment OK → accepted")
end

-- Test 6: TC mismatch, accept_trimmed ON but clip range NOT contained
-- Clip absolute range: 89850-89950. Candidate starts at 89900, 20 frames → ends at 89920.
-- Candidate doesn't fully contain 89850-89950 → rejected.
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = true, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {value = 89900, rate = 25},
    })
    local media_probe = make_media_probe_fn({
        ["/new/A026_C007.mov"] = {duration_frames = 20, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080},
    })

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 0, "not contained: expected 0 candidates")
    print("  ✓ TC mismatch + accept_trimmed ON + NOT contained → rejected")
end

print("\n--- resolution matching ---")

-- Test 7: Resolution match
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = false,
        match_resolution = true, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({})
    local media_probe = make_media_probe_fn({
        ["/new/A026_C007.mov"] = {width = 1920, height = 1080, fps_num = 25, fps_den = 1},
    })

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 1, "resolution match: expected 1")
    print("  ✓ matching resolution → accepted")
end

-- Test 8: Resolution mismatch → rejected
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = false,
        match_resolution = true, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({})
    local media_probe = make_media_probe_fn({
        ["/new/A026_C007.mov"] = {width = 3840, height = 2160, fps_num = 25, fps_den = 1},
    })

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 0, "resolution mismatch: expected 0")
    print("  ✓ resolution mismatch → rejected")
end

print("\n--- TC-only matching (no filename) ---")

-- Test 9: TC-only match — finds candidate by TC regardless of filename
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "transcoded_v2.mov", path = "/new/transcoded_v2.mov"},
    })
    local rules = {
        match_filename = false, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/transcoded_v2.mov"] = {value = 89750, rate = 25},
    })
    local media_probe = make_media_probe_fn({})

    -- When filename is off, we need all candidates in the index
    -- The function should check ALL candidates, not just filename-matched ones
    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 1, string.format("TC-only: expected 1, got %d", #candidates))
    print("  ✓ TC-only match (no filename) → candidate found")
end

print("\n--- combined criteria ---")

-- Test 10: filename + TC + resolution — all must pass
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/vol1/A026_C007.mov"},
        {filename = "A026_C007.mov", path = "/vol2/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = true, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/vol1/A026_C007.mov"] = {value = 89750, rate = 25},
        ["/vol2/A026_C007.mov"] = {value = 89750, rate = 25},
    })
    local media_probe = make_media_probe_fn({
        ["/vol1/A026_C007.mov"] = {width = 1920, height = 1080, fps_num = 25, fps_den = 1},
        ["/vol2/A026_C007.mov"] = {width = 3840, height = 2160, fps_num = 25, fps_den = 1},  -- wrong res
    })

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 1, string.format("combined: expected 1, got %d", #candidates))
    assert(candidates[1].path == "/vol1/A026_C007.mov", "wrong candidate survived")
    print("  ✓ filename + TC + resolution: only candidate passing all 3 survives")
end

print("\n--- no stored TC ---")

-- Test 11: Clip has no stored TC, TC matching enabled → accept on filename
-- (Can't verify TC when we don't know the original TC)
do
    local clip = make_clip_info({
        media_start_tc_value = nil,
        media_start_tc_rate = nil,
    })
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {value = 89750, rate = 25},
    })
    local media_probe = make_media_probe_fn({})

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 1, "no stored TC: should accept on filename")
    print("  ✓ no stored TC + TC matching on → accepts on filename alone")
end

-- Test 12: Candidate has no TC, TC matching enabled → accept on filename
do
    local clip = make_clip_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({})  -- returns nil for everything
    local media_probe = make_media_probe_fn({})

    local candidates = relinker.find_candidates_for_clip(clip, index, rules, probe, media_probe)
    assert(#candidates == 1, "candidate no TC: should accept on filename")
    print("  ✓ candidate has no TC + TC matching on → accepts on filename alone")
end

print("\n✅ test_candidate_filtering.lua passed")
