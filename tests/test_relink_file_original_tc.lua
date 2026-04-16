-- Test: Relinker accepts candidate matching file_original_timecode
--
-- Verifies:
-- 1. Candidate whose probed TC matches file_original_tc (but not start_tc_value)
--    is accepted as a CLEAN match (tc_mismatch = false)
-- 2. Candidate whose probed TC matches start_tc_value is still accepted as before
-- 3. Candidate whose probed TC matches neither field falls through to
--    trimmed-media containment (tc_mismatch = true) or rejected
--
-- Domain values from the two-clips fixture:
--   Override master clip:  start_tc_value = 1194321 (13:16:12:21 at 25fps)
--   File container TC:     file_original_tc = 11383  (00:07:35:08 at 25fps)

require("test_env")
local relinker = require("core.media_relinker")

print("=== test_relink_file_original_tc.lua ===")

-- ─────────────────────────────────────────────────────────────
-- Test 1: Candidate matches file_original_tc → clean accept
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 1: Candidate matches file_original_tc (clean accept) ---")

-- Media info for an override clip: displayed TC ≠ file container TC
local media_info_override = {
    media_path = "/fake/VFX_01.mov",
    media_name = "VFX_01.mov",
    media_start_tc_value = 1194321,    -- 13:16:12:21 (override)
    media_start_tc_rate = 25,
    media_file_original_tc = 11383,    -- 00:07:35:08 (file container)
    width = 1280,
    height = 1080,
    clips = {
        {
            clip_id = "clip-001",
            source_in = 1194321,       -- first frame, in override TC space
            source_out = 1194346,      -- 25 frames later
            fps_num = 25, fps_den = 1,
            clip_kind = "video",
        },
    },
}

-- Candidate file probes to the file container TC (00:07:35:08)
-- This does NOT match start_tc_value (13:16:12:21) but DOES match file_original_tc
local candidate_index = {
    ["vfx_01.mov"] = { "/disk/fixtures/VFX_01.mov" },
}

local probe_fn = function(path)
    return {
        start_tc_value = 11383,        -- probed container TC = 00:07:35:08
        start_tc_rate = 25,
        width = 1280,
        height = 1080,
        fps_num = 25, fps_den = 1,
        duration_frames = 250,         -- 10 seconds
    }
end

local results = relinker.find_candidates_for_media(
    media_info_override, candidate_index,
    { match_filename = true, match_timecode = true }, probe_fn)

assert(#results > 0, "Candidate matching file_original_tc must be accepted (got 0 results)")
assert(results[1].tc_mismatch == false,
    "Match on file_original_tc must be a clean match (tc_mismatch=false), not containment-fallback")
print("  ✓ Candidate accepted via file_original_tc match (clean, no tc_mismatch)")

-- ─────────────────────────────────────────────────────────────
-- Test 2: Candidate matches start_tc_value → clean accept (existing behavior)
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 2: Candidate matches start_tc_value (existing behavior) ---")

-- Candidate probes to the override TC (file was re-timecoded to bake the override)
local probe_fn_override_match = function(path)
    return {
        start_tc_value = 1194321,      -- probed container TC = 13:16:12:21
        start_tc_rate = 25,
        width = 1280, height = 1080,
        fps_num = 25, fps_den = 1,
        duration_frames = 250,
    }
end

local results2 = relinker.find_candidates_for_media(
    media_info_override, candidate_index,
    { match_filename = true, match_timecode = true }, probe_fn_override_match)

assert(#results2 > 0, "Candidate matching start_tc_value must still be accepted")
assert(results2[1].tc_mismatch == false,
    "Match on start_tc_value must be clean (tc_mismatch=false)")
print("  ✓ Candidate accepted via start_tc_value match (existing behavior preserved)")

-- ─────────────────────────────────────────────────────────────
-- Test 3: Candidate matches neither field → tc_mismatch or rejected
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 3: Candidate matches neither field → mismatch/rejected ---")

local probe_fn_neither = function(path)
    return {
        start_tc_value = 99999,        -- matches neither 1194321 nor 11383
        start_tc_rate = 25,
        width = 1280, height = 1080,
        fps_num = 25, fps_den = 1,
        duration_frames = 250,
    }
end

-- Without accept_trimmed_media: should be rejected
local results3a = relinker.find_candidates_for_media(
    media_info_override, candidate_index,
    { match_filename = true, match_timecode = true, accept_trimmed_media = false }, probe_fn_neither)
assert(#results3a == 0, string.format(
    "Candidate matching neither TC must be rejected when trimmed not accepted (got %d)", #results3a))
print("  ✓ Neither-match rejected when accept_trimmed_media=false")

-- With accept_trimmed_media: should be tc_mismatch (containment fallback)
local results3b = relinker.find_candidates_for_media(
    media_info_override, candidate_index,
    { match_filename = true, match_timecode = true, accept_trimmed_media = true }, probe_fn_neither)
if #results3b > 0 then
    assert(results3b[1].tc_mismatch == true,
        "Neither-match with accept_trimmed_media must be tc_mismatch=true")
    print("  ✓ Neither-match is tc_mismatch=true when accept_trimmed_media=true")
else
    print("  ✓ Neither-match rejected even with accept_trimmed_media (no containment)")
end

-- ─────────────────────────────────────────────────────────────
-- Test 4: Camera footage (no file_original_tc) — existing behavior unchanged
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 4: Camera footage — no file_original_tc field ---")

local media_info_camera = {
    media_path = "/fake/camera.mov",
    media_name = "camera.mov",
    media_start_tc_value = 11383,      -- 00:07:35:08 (file TC = display TC)
    media_start_tc_rate = 25,
    -- media_file_original_tc is nil (no override)
    width = 1920, height = 1080,
    clips = {
        { clip_id = "clip-cam", source_in = 11383, source_out = 11408,
          fps_num = 25, fps_den = 1, clip_kind = "video" },
    },
}

local probe_fn_camera = function(path)
    return {
        start_tc_value = 11383,        -- matches start_tc_value
        start_tc_rate = 25,
        width = 1920, height = 1080,
        fps_num = 25, fps_den = 1,
        duration_frames = 500,
    }
end

local results4 = relinker.find_candidates_for_media(
    media_info_camera, { ["camera.mov"] = { "/disk/camera.mov" } },
    { match_filename = true, match_timecode = true }, probe_fn_camera)
assert(#results4 > 0, "Camera footage must still match on start_tc_value")
assert(results4[1].tc_mismatch == false, "Camera footage must be clean match")
print("  ✓ Camera footage matches on start_tc_value (no file_original_tc needed)")

print("\n✅ test_relink_file_original_tc.lua passed")
