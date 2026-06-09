#!/usr/bin/env luajit
--- T005: Candidate filtering — find_candidates_for_media + check_clip_containment
require("test_env")

print("=== test_candidate_filtering.lua ===")

local relinker = require("core.media_relinker")

-- Helper: build a media_info struct (media-level, no clip fields)
local function make_media_info(overrides)
    local defaults = {
        media_path = "/offline/A026_C007.mov",
        media_name = "A026_C007.mov",
        media_start_tc_value = 89750, -- 00:59:50:00 @ 25fps
        media_start_tc_rate = 25,
        width = 1920,
        height = 1080,
    }
    if overrides then
        for k, v in pairs(overrides) do defaults[k] = v end
    end
    return defaults
end

-- Helper: build a candidate entry
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
    return function(path)
        return probe_map[path]
    end
end

---------------------------------------------------------------------------------
-- find_candidates_for_media(media_info, candidate_index, matching_rules, probe_fn)
-- Returns array of {path, start_tc_value, start_tc_rate, probe_result, tc_mismatch}
---------------------------------------------------------------------------------

print("\n--- filename-only matching ---")

-- Test 1: Filename match finds candidate
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = false,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({})

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, string.format("expected 1 candidate, got %d", #candidates))
    assert(candidates[1].path == "/new/A026_C007.mov", "wrong path")
    print("  ✓ filename-only match returns candidate")
end

-- Test 2: Filename mismatch → no candidates
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "B001_C001.mov", path = "/new/B001_C001.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = false,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({})

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 0, "filename mismatch: expected 0 candidates")
    print("  ✓ filename mismatch → 0 candidates")
end

print("\n--- timecode matching ---")

-- Test 3: TC match — candidate TC matches stored TC
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {start_tc_value = 89750, start_tc_rate = 25},
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, string.format("TC match: expected 1, got %d", #candidates))
    assert(not candidates[1].tc_mismatch, "TC matched — should not be marked as mismatch")
    print("  ✓ matching TC → candidate accepted")
end

-- Test 4: TC mismatch, accept_trimmed_media OFF → rejected
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {start_tc_value = 90000, start_tc_rate = 25},
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 0, "TC mismatch without accept_trimmed: expected 0")
    print("  ✓ TC mismatch + accept_trimmed OFF → rejected")
end

-- Test 5: TC mismatch, accept_trimmed_media ON → accepted with tc_mismatch flag
-- (Containment check is now done by caller via check_clip_containment)
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = true, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {start_tc_value = 89800, start_tc_rate = 25,
            duration_frames = 500, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080},
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, string.format("trimmed accepted: expected 1, got %d", #candidates))
    assert(candidates[1].tc_mismatch == true, "should be marked as TC mismatch")
    assert(candidates[1].probe_result ~= nil, "probe_result should be attached")
    print("  ✓ TC mismatch + accept_trimmed ON → accepted with tc_mismatch flag")
end

-- Test 6: TC mismatch, accept_trimmed ON — candidate still passes media-level filter
-- (even if clip wouldn't fit — that's determined per-clip by the caller)
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = true, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {start_tc_value = 89900, start_tc_rate = 25,
            duration_frames = 20, fps_num = 25, fps_den = 1,
            width = 1920, height = 1080},
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, string.format(
        "media-level should accept (containment is per-clip): expected 1, got %d", #candidates))
    assert(candidates[1].tc_mismatch == true, "should be marked as TC mismatch")
    print("  ✓ TC mismatch + accept_trimmed ON → accepted at media level (containment deferred)")
end

print("\n--- check_clip_containment ---")

-- Clip fits inside candidate range
do
    -- Clip absolute range: 89850-89950 @ 25fps
    -- Candidate: TC=89800, duration=500 → [89800, 90300) → contains clip
    local clip = {source_in = 89850, source_out = 89950, fps_num = 25, fps_den = 1}
    local probe_result = {start_tc_value = 89800, start_tc_rate = 25,
        duration_frames = 500, fps_num = 25, fps_den = 1}
    assert(relinker.check_clip_containment(clip, probe_result, 25) == true,
        "clip [89850,89950] should be contained in [89800,90300)")
    print("  ✓ clip [89850,89950] contained in candidate [89800,90300)")
end

-- Clip extends past candidate range
do
    -- Clip absolute range: 89850-89950 @ 25fps
    -- Candidate: TC=89900, duration=20 → [89900, 89920) → clip starts before candidate
    local clip = {source_in = 89850, source_out = 89950, fps_num = 25, fps_den = 1}
    local probe_result = {start_tc_value = 89900, start_tc_rate = 25,
        duration_frames = 20, fps_num = 25, fps_den = 1}
    assert(relinker.check_clip_containment(clip, probe_result, 25) == false,
        "clip [89850,89950] should NOT be contained in [89900,89920)")
    print("  ✓ clip [89850,89950] not contained in candidate [89900,89920)")
end

-- No probe TC → containment cannot be verified → returns false
do
    local clip = {source_in = 89850, source_out = 89950, fps_num = 25, fps_den = 1}
    local probe_result = {duration_frames = 500, fps_num = 25, fps_den = 1}
    assert(relinker.check_clip_containment(clip, probe_result, 25) == false,
        "no TC in probe → cannot verify containment")
    print("  ✓ no candidate TC → containment check returns false")
end

print("\n--- resolution matching ---")

-- Test 7: Resolution match
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = false,
        match_resolution = true, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {width = 1920, height = 1080, fps_num = 25, fps_den = 1},
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, "resolution match: expected 1")
    print("  ✓ matching resolution → accepted")
end

-- Test 8: Resolution mismatch → rejected
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = false,
        match_resolution = true, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/A026_C007.mov"] = {width = 3840, height = 2160, fps_num = 25, fps_den = 1},
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 0, "resolution mismatch: expected 0")
    print("  ✓ resolution mismatch → rejected")
end

print("\n--- TC-only matching (no filename) ---")

-- Test 9: TC-only match — finds candidate by TC regardless of filename
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "transcoded_v2.mov", path = "/new/transcoded_v2.mov"},
    })
    local rules = {
        match_filename = false, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({
        ["/new/transcoded_v2.mov"] = {start_tc_value = 89750, start_tc_rate = 25},
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, string.format("TC-only: expected 1, got %d", #candidates))
    print("  ✓ TC-only match (no filename) → candidate found")
end

print("\n--- combined criteria ---")

-- Test 10: filename + TC + resolution — all must pass
do
    local media = make_media_info()
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
        ["/vol1/A026_C007.mov"] = {start_tc_value = 89750, start_tc_rate = 25,
            width = 1920, height = 1080, fps_num = 25, fps_den = 1},
        ["/vol2/A026_C007.mov"] = {start_tc_value = 89750, start_tc_rate = 25,
            width = 3840, height = 2160, fps_num = 25, fps_den = 1},  -- wrong res
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, string.format("combined: expected 1, got %d", #candidates))
    assert(candidates[1].path == "/vol1/A026_C007.mov", "wrong candidate survived")
    print("  ✓ filename + TC + resolution: only candidate passing all 3 survives")
end

print("\n--- no stored TC ---")

-- Test 11: Media has no stored TC, TC matching enabled → accept on filename
do
    local media = make_media_info({
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
        ["/new/A026_C007.mov"] = {start_tc_value = 89750, start_tc_rate = 25},
    })

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, "no stored TC: should accept on filename")
    print("  ✓ no stored TC + TC matching on → accepts on filename alone")
end

-- Test 12: Candidate has no TC, TC matching enabled → accept on filename
do
    local media = make_media_info()
    local index = make_candidate_index({
        {filename = "A026_C007.mov", path = "/new/A026_C007.mov"},
    })
    local rules = {
        match_filename = true, match_timecode = true,
        match_resolution = false, match_frame_rate = false,
        accept_trimmed_media = false, accept_filename_suffixes = false,
    }
    local probe = make_probe_fn({})  -- returns nil for everything

    local candidates = relinker.find_candidates_for_media(media, index, rules, probe)
    assert(#candidates == 1, "candidate no TC: should accept on filename")
    print("  ✓ candidate has no TC + TC matching on → accepts on filename alone")
end

print("\n✅ test_candidate_filtering.lua passed")
