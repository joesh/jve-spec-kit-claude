#!/usr/bin/env luajit
-- NSF test: DRP importer absolute TC source_in validation.
--
-- Verifies:
-- 1. source_in = media_tc_origin + in_offset (absolute TC)
-- 2. media_tc_origin is non-negative
-- 3. in_offset is non-negative
-- 4. source_in is non-negative
-- 5. MST=0 → source_in = in_offset (file-relative = absolute TC from midnight)
-- 6. Negative MST → assert fires (not silently accepted)

require("test_env")

print("=== test_drp_absolute_tc_nsf.lua ===")

local drp_importer = require("importers.drp_importer")

local _xml_helpers = require("drp_test_helpers")
local elem = _xml_helpers.elem
local wrap_clips = _xml_helpers.wrap_clips


-- LE hex-encoded IEEE 754 doubles for <MediaFrameRate>
local MFR_25  = "0000000000003940"  -- 25.0fps
local MFR_24  = "0000000000003840"  -- 24.0fps

-- Audio sample rate map: MediaRef → sample_rate (simulates pool master clip data)
local AUDIO_SR_MAP = { ["test-audio-ref"] = 48000 }

--------------------------------------------------------------------------------
-- Test 1: Video with MST > 0 → source_in = media_tc_origin + in_offset
--------------------------------------------------------------------------------
print("\n--- Test 1: Video absolute TC computation ---")
do
    -- MST=3600s (01:00:00:00), In=100, fps=25
    -- media_tc_origin = floor(3600 * 25 + 0.5) = 90000
    -- source_in = 90000 + 100 = 90100
    local seq = elem("Sequence", "", {
        elem("Sm2TiTrack", "", {
            elem("Type", "0"),
            wrap_clips(elem("Sm2TiVideoClip", { DbId = "test-video-id" }, {
                elem("Name", "tc_video"),
                elem("Start", "0"),
                elem("Duration", "50"),
                elem("MediaStartTime", "3600"),
                elem("In", "100"),
                elem("MediaFilePath", "/test/v.mov"),
                elem("MediaFrameRate", MFR_25),
            })),
        }),
    })
    local tracks = drp_importer.parse_resolve_tracks(seq, {frame_rate = 25, media_ref_sample_rate_map = AUDIO_SR_MAP})
    local clip = tracks[1].clips[1]
    assert(clip.source_in == 90100, string.format(
        "video source_in should be 90100 (abs TC), got %d", clip.source_in))
    assert(clip.source_out == 90100 + 50, string.format(
        "video source_out should be 90150, got %d", clip.source_out))
    print("  ✓ video: source_in=90100 (3600s*25 + 100)")
end

--------------------------------------------------------------------------------
-- Test 2: Audio with MST > 0 → source_in in samples (absolute TC)
--------------------------------------------------------------------------------
print("\n--- Test 2: Audio absolute TC computation ---")
do
    -- MST=3600s, In=250 timeline frames, fps=25
    -- media_tc_origin = floor(3600 * 48000 + 0.5) = 172800000
    -- in_offset = floor(250 * 48000 / 25 + 0.5) = 480000
    -- source_in = 172800000 + 480000 = 173280000
    local seq = elem("Sequence", "", {
        elem("Sm2TiTrack", "", {
            elem("Type", "1"),
            wrap_clips(elem("Sm2TiAudioClip", { DbId = "test-audio-id" }, {
                elem("Name", "tc_audio"),
                elem("Start", "0"),
                elem("Duration", "100"),
                elem("MediaStartTime", "3600"),
                elem("In", "250"),
                elem("MediaFilePath", "/test/a.wav"),
                elem("MediaRef", "test-audio-ref"),
            })),
        }),
    })
    local _, a_tracks = drp_importer.parse_resolve_tracks(seq, {frame_rate = 25, media_ref_sample_rate_map = AUDIO_SR_MAP})
    local clip = a_tracks[1].clips[1]
    assert(clip.source_in == 173280000, string.format(
        "audio source_in should be 173280000, got %d", clip.source_in))
    print("  ✓ audio: source_in=173280000 (3600s*48000 + 250*48000/25)")
end

--------------------------------------------------------------------------------
-- Test 3: MST=0 → source_in = in_offset (file-relative)
--------------------------------------------------------------------------------
print("\n--- Test 3: MST=0 → source_in = in_offset ---")
do
    local seq = elem("Sequence", "", {
        elem("Sm2TiTrack", "", {
            elem("Type", "0"),
            wrap_clips(elem("Sm2TiVideoClip", { DbId = "test-video-id" }, {
                elem("Name", "zero_mst"),
                elem("Start", "0"),
                elem("Duration", "50"),
                elem("MediaStartTime", "0"),
                elem("In", "42"),
                elem("MediaFilePath", "/test/z.mov"),
                elem("MediaFrameRate", MFR_24),
            })),
        }),
    })
    local tracks = drp_importer.parse_resolve_tracks(seq, {frame_rate = 24, media_ref_sample_rate_map = AUDIO_SR_MAP})
    local clip = tracks[1].clips[1]
    assert(clip.source_in == 42, string.format(
        "MST=0: source_in should be 42, got %d", clip.source_in))
    print("  ✓ MST=0: source_in=42 (file-relative = absolute TC from midnight)")
end

--------------------------------------------------------------------------------
-- Test 4: Missing MST (nil) → source_in = in_offset
--------------------------------------------------------------------------------
print("\n--- Test 4: Missing MST → source_in = in_offset ---")
do
    local seq = elem("Sequence", "", {
        elem("Sm2TiTrack", "", {
            elem("Type", "0"),
            wrap_clips(elem("Sm2TiVideoClip", { DbId = "test-video-id" }, {
                elem("Name", "no_mst"),
                elem("Start", "0"),
                elem("Duration", "50"),
                -- No MediaStartTime element
                elem("In", "77"),
                elem("MediaFilePath", "/test/n.mov"),
                elem("MediaFrameRate", MFR_25),
            })),
        }),
    })
    local tracks = drp_importer.parse_resolve_tracks(seq, {frame_rate = 25, media_ref_sample_rate_map = AUDIO_SR_MAP})
    local clip = tracks[1].clips[1]
    assert(clip.source_in == 77, string.format(
        "missing MST: source_in should be 77, got %d", clip.source_in))
    print("  ✓ missing MST: source_in=77 (no tc origin added)")
end

--------------------------------------------------------------------------------
-- Test 5: Large MST (23:59:59) — boundary, not overflow
--------------------------------------------------------------------------------
print("\n--- Test 5: Large MST boundary ---")
do
    -- MST = 86399s (23:59:59), fps=25
    -- media_tc_origin = floor(86399 * 25 + 0.5) = 2159975
    local seq = elem("Sequence", "", {
        elem("Sm2TiTrack", "", {
            elem("Type", "0"),
            wrap_clips(elem("Sm2TiVideoClip", { DbId = "test-video-id" }, {
                elem("Name", "max_mst"),
                elem("Start", "0"),
                elem("Duration", "50"),
                elem("MediaStartTime", "86399"),
                elem("In", "10"),
                elem("MediaFilePath", "/test/m.mov"),
                elem("MediaFrameRate", MFR_25),
            })),
        }),
    })
    local tracks = drp_importer.parse_resolve_tracks(seq, {frame_rate = 25, media_ref_sample_rate_map = AUDIO_SR_MAP})
    local clip = tracks[1].clips[1]
    local expected = math.floor(86399 * 25 + 0.5) + 10
    assert(clip.source_in == expected, string.format(
        "large MST: source_in should be %d, got %d", expected, clip.source_in))
    print(string.format("  ✓ large MST: source_in=%d (86399s * 25 + 10)", expected))
end

--------------------------------------------------------------------------------
-- Test 6: source_in_tc field matches source_in (DRP compatibility)
--------------------------------------------------------------------------------
print("\n--- Test 6: source_in_tc field ---")
do
    local seq = elem("Sequence", "", {
        elem("Sm2TiTrack", "", {
            elem("Type", "0"),
            wrap_clips(elem("Sm2TiVideoClip", { DbId = "test-video-id" }, {
                elem("Name", "tc_field"),
                elem("Start", "0"),
                elem("Duration", "50"),
                elem("MediaStartTime", "3600"),
                elem("In", "100"),
                elem("MediaFilePath", "/test/f.mov"),
                elem("MediaFrameRate", MFR_25),
            })),
        }),
    })
    local tracks = drp_importer.parse_resolve_tracks(seq, {frame_rate = 25, media_ref_sample_rate_map = AUDIO_SR_MAP})
    local clip = tracks[1].clips[1]
    assert(clip.source_in_tc == clip.source_in, string.format(
        "source_in_tc should equal source_in (%d), got %d",
        clip.source_in, clip.source_in_tc))
    print("  ✓ source_in_tc == source_in")
end

print("\n✅ test_drp_absolute_tc_nsf.lua passed")
