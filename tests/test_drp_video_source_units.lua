#!/usr/bin/env luajit
-- TDD regression test: DRP importer source_in is ABSOLUTE TC.
--
-- DRP field meanings (confirmed from real DRP XML analysis):
--   <MediaStartTime> = file's TC origin in SECONDS since midnight (e.g., 45274 = 12:34:34)
--   <In>             = source mark-in offset in TIMELINE FRAMES (file-relative)
--   <Start>          = timeline position (frames)
--   <Duration>       = timeline duration (frames)
--
-- source_in = media_tc_origin + in_offset (absolute TC in clip-rate units).
-- media_tc_origin = floor(MediaStartTime * rate + 0.5) where rate = frame_rate for
-- video, sample_rate for audio. MST=0 → source_in = in_offset (naturally correct).

require("test_env")

print("=== test_drp_video_source_units.lua ===")

local drp_importer = require("importers.drp_importer")

-- Helper: construct a mock XML element
local function elem(tag, text_or_attrs, children)
    local text = type(text_or_attrs) == "string" and text_or_attrs or ""
    local attrs = type(text_or_attrs) == "table" and text_or_attrs or {}
    return {
        tag = tag,
        attrs = attrs,
        children = children or {},
        text = text,
    }
end

-- Helper: wrap clips in Items > Element structure matching real DRP XML
local function wrap_clips(...)
    local elements = {}
    for _, clip in ipairs({...}) do
        table.insert(elements, elem("Element", "", {clip}))
    end
    return elem("Items", "", elements)
end

--------------------------------------------------------------------------------
-- Test 1: Video clip with empty <In/> and MST → source_in = media_tc_origin
--------------------------------------------------------------------------------

print("\n--- Test 1: Video untrimmed clip (In empty) → source_in = media_tc_origin ---")

local seq_elem = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),  -- 0 = VIDEO
        wrap_clips(
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "test_video_clip"),
                elem("Start", "86400"),
                elem("Duration", "1496"),
                elem("MediaStartTime", "45274"),  -- 12:34:34 in seconds (file TC origin)
                elem("In", ""),                    -- empty = untrimmed, start at file beginning
                elem("MediaFilePath", "/test/C095.mov"),
                elem("MediaFrameRate", "0000000000003840"),  -- 24fps LE double
            })
        ),
    }),
})

local video_tracks = drp_importer.parse_resolve_tracks(seq_elem, {frame_rate = 24})

assert(#video_tracks == 1, "Expected 1 video track, got " .. #video_tracks)
assert(#video_tracks[1].clips == 1, "Expected 1 video clip")

local clip = video_tracks[1].clips[1]

-- source_in = media_tc_origin + 0 (untrimmed) = floor(45274 * 24 + 0.5) = 1086576
local mst1 = math.floor(45274 * 24 + 0.5)
assert(clip.source_in == mst1, string.format(
    "Untrimmed video source_in should be %d (media_tc_origin), got %d", mst1, clip.source_in))
print("  ✓ Video source_in = " .. mst1 .. " (absolute TC, untrimmed)")

-- source_out = source_in + duration
assert(clip.source_out == mst1 + 1496, string.format(
    "Video source_out should be %d, got %d", mst1 + 1496, clip.source_out))
print("  ✓ Video source_out = " .. (mst1 + 1496))

--------------------------------------------------------------------------------
-- Test 2: Video clip with <In> offset → source_in = media_tc_origin + In
--------------------------------------------------------------------------------

print("\n--- Test 2: Video trimmed clip (In=100) → source_in = media_tc_origin + 100 ---")

local seq_trim = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "trimmed_video"),
                elem("Start", "86400"),
                elem("Duration", "200"),
                elem("MediaStartTime", "45274"),
                elem("In", "100"),  -- starts 100 frames into the file
                elem("MediaFilePath", "/test/C095.mov"),
                elem("MediaFrameRate", "0000000000003840"),  -- 24fps LE double
            })
        ),
    }),
})

local v_trim = drp_importer.parse_resolve_tracks(seq_trim, {frame_rate = 24})
local trim_clip = v_trim[1].clips[1]

local mst2 = math.floor(45274 * 24 + 0.5)
assert(trim_clip.source_in == mst2 + 100, string.format(
    "Trimmed video source_in should be %d (abs TC), got %d", mst2 + 100, trim_clip.source_in))
print("  ✓ Video source_in = " .. (mst2 + 100) .. " (absolute TC, trimmed)")

assert(trim_clip.source_out == mst2 + 300, string.format(
    "Trimmed video source_out should be %d, got %d", mst2 + 300, trim_clip.source_out))
print("  ✓ Video source_out = " .. (mst2 + 300))

--------------------------------------------------------------------------------
-- Test 3: Audio clip with empty <In/> → source_in = media_tc_origin in samples
--------------------------------------------------------------------------------

print("\n--- Test 3: Audio untrimmed clip → source_in = media_tc_origin samples ---")

local seq_audio = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "1"),  -- 1 = AUDIO
        wrap_clips(
            elem("Sm2TiAudioClip", { DbId = "a1" }, {
                elem("Name", "test_audio.WAV"),
                elem("Start", "86400"),
                elem("Duration", "73794"),        -- timeline frames
                elem("MediaStartTime", "45845"),  -- file TC origin (12:44:05 seconds)
                elem("In", ""),                    -- empty = start at file beginning
                elem("MediaFilePath", "/test/audio.wav"),
                elem("MediaRef", "test-audio-ref"),
            })
        ),
    }),
})

local _, a_tracks = drp_importer.parse_resolve_tracks(seq_audio, {frame_rate = 24, media_ref_sample_rate_map = { ["test-audio-ref"] = 48000 }})

assert(#a_tracks == 1, "Expected 1 audio track, got " .. #a_tracks)
local audio_clip = a_tracks[1].clips[1]

-- media_tc_origin = floor(45845 * 48000 + 0.5) = 2200560000 samples
local audio_mst = math.floor(45845 * 48000 + 0.5)
assert(audio_clip.source_in == audio_mst, string.format(
    "Untrimmed audio source_in should be %d (media_tc_origin), got %d",
    audio_mst, audio_clip.source_in))
print("  ✓ Audio source_in = " .. audio_mst .. " samples (absolute TC, untrimmed)")

-- source_out = source_in + duration_samples
local expected_source_dur = 147588000  -- 73794 frames × 48000/24
assert(audio_clip.source_out == audio_mst + expected_source_dur, string.format(
    "Audio source_out should be %d, got %d",
    audio_mst + expected_source_dur, audio_clip.source_out))
print("  ✓ Audio source_out = " .. (audio_mst + expected_source_dur))

--------------------------------------------------------------------------------
-- Test 4: Audio clip with <In> offset → source_in = media_tc_origin + in_samples
--------------------------------------------------------------------------------

print("\n--- Test 4: Audio trimmed clip (In=73794) → source_in = media_tc_origin + in_samples ---")

local seq_audio_trim = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "1"),
        wrap_clips(
            elem("Sm2TiAudioClip", { DbId = "a1" }, {
                elem("Name", "test_audio.WAV"),
                elem("Start", "160194"),
                elem("Duration", "30867"),
                elem("MediaStartTime", "45845"),
                elem("In", "73794"),  -- 73794 timeline frames into the audio file
                elem("MediaFilePath", "/test/audio.wav"),
                elem("MediaRef", "test-audio-ref"),
            })
        ),
    }),
})

local _, a_trim = drp_importer.parse_resolve_tracks(seq_audio_trim, {frame_rate = 24, media_ref_sample_rate_map = { ["test-audio-ref"] = 48000 }})
local audio_trim_clip = a_trim[1].clips[1]

-- in_offset = floor(73794 * 48000 / 24 + 0.5) = 147588000 samples
local in_offset_samples = 147588000
local audio_mst4 = math.floor(45845 * 48000 + 0.5)
assert(audio_trim_clip.source_in == audio_mst4 + in_offset_samples, string.format(
    "Trimmed audio source_in should be %d (abs TC), got %d",
    audio_mst4 + in_offset_samples, audio_trim_clip.source_in))
print("  ✓ Audio source_in = " .. (audio_mst4 + in_offset_samples) .. " samples (absolute TC)")

--------------------------------------------------------------------------------
-- Test 5: Different MediaStartTime, same In=0 → different source_in (different TC origins)
--------------------------------------------------------------------------------

print("\n--- Test 5: Different MediaStartTime, same In=0 → different source_in ---")

local seq_regression = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "clip_a"),
                elem("Start", "86400"),
                elem("Duration", "100"),
                elem("MediaStartTime", "45274"),  -- TC 12:34:34
                elem("In", ""),
                elem("MediaFilePath", "/test/a.mov"),
                elem("MediaFrameRate", "0000000000003840"),  -- 24fps LE double
            }),
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "clip_b"),
                elem("Start", "86500"),
                elem("Duration", "100"),
                elem("MediaStartTime", "99999"),  -- completely different TC
                elem("In", ""),
                elem("MediaFilePath", "/test/b.mov"),
                elem("MediaFrameRate", "0000000000003840"),  -- 24fps LE double
            })
        ),
    }),
})

local v_reg = drp_importer.parse_resolve_tracks(seq_regression, {frame_rate = 24})
local mst_a = math.floor(45274 * 24 + 0.5)
local mst_b = math.floor(99999 * 24 + 0.5)
assert(v_reg[1].clips[1].source_in == mst_a, string.format(
    "clip_a source_in should be %d (abs TC), got %d", mst_a, v_reg[1].clips[1].source_in))
assert(v_reg[1].clips[2].source_in == mst_b, string.format(
    "clip_b source_in should be %d (abs TC), got %d", mst_b, v_reg[1].clips[2].source_in))
print("  ✓ Different MediaStartTime → different source_in (absolute TC)")

---------------------------------------------------------------------------------
-- Test 6: MediaStartTime flows to clip struct + media_lookup
---------------------------------------------------------------------------------

print("\n--- Test 6: MediaStartTime stored on clip and media_lookup ---")

local seq_mst = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "clip_with_mst"),
                elem("Start", "86400"),
                elem("Duration", "200"),
                elem("MediaStartTime", "45274.12"),  -- 12:34:34 + fractional
                elem("In", ""),
                elem("MediaFilePath", "/test/mst_test.mov"),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            })
        ),
    })
})

local v_mst, _, media_map = drp_importer.parse_resolve_tracks(seq_mst, {frame_rate = 25})
local clip_mst = v_mst[1].clips[1]

-- Clip struct should have media_start_time (raw seconds from DRP)
assert(clip_mst.media_start_time, "clip should have media_start_time")
assert(math.abs(clip_mst.media_start_time - 45274.12) < 0.01,
    string.format("clip media_start_time should be 45274.12, got %s",
    tostring(clip_mst.media_start_time)))
print("  ✓ Clip struct has media_start_time=45274.12 (raw seconds)")

-- media_lookup entry should have media_start_time
local media_entry = media_map["/test/mst_test.mov"]
assert(media_entry, "media_lookup should have entry for /test/mst_test.mov")
assert(media_entry.media_start_time, "media_lookup entry should have media_start_time")
assert(math.abs(media_entry.media_start_time - 45274.12) < 0.01,
    string.format("media_lookup media_start_time should be 45274.12, got %s",
    tostring(media_entry.media_start_time)))
print("  ✓ media_lookup entry has media_start_time=45274.12")

-- source_in = media_tc_origin + 0 = floor(45274.12 * 25 + 0.5) = 1131853
local expected_mst6_origin = math.floor(45274.12 * 25 + 0.5)
assert(expected_mst6_origin == 1131853, "expected 1131853 frames, got " .. expected_mst6_origin)
assert(clip_mst.source_in == expected_mst6_origin, string.format(
    "source_in should be %d (abs TC), got %d", expected_mst6_origin, clip_mst.source_in))
print("  ✓ source_in = " .. expected_mst6_origin .. " (absolute TC from MST)")

-- Zero MediaStartTime should also be stored (not nil)
local seq_zero_mst = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "clip_zero_mst"),
                elem("Start", "0"),
                elem("Duration", "100"),
                elem("MediaStartTime", "0"),
                elem("In", ""),
                elem("MediaFilePath", "/test/zero_mst.mov"),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            })
        ),
    })
})

local v_zmst, _, media_map_z = drp_importer.parse_resolve_tracks(seq_zero_mst, {frame_rate = 25})
assert(v_zmst[1].clips[1].media_start_time == 0,
    "zero MediaStartTime should be stored as 0, not nil")
assert(media_map_z["/test/zero_mst.mov"].media_start_time == 0,
    "zero MediaStartTime in media_lookup should be 0")
-- MST=0 → source_in = 0 (absolute TC from midnight = file-relative)
assert(v_zmst[1].clips[1].source_in == 0,
    "MST=0 untrimmed → source_in should be 0")
print("  ✓ Zero MediaStartTime stored as 0; source_in=0")

print("\n✅ test_drp_video_source_units.lua passed")
