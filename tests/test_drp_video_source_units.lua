#!/usr/bin/env luajit
-- TDD regression test: DRP importer source_in must come from <In> element,
-- NOT from <MediaStartTime>.
--
-- DRP field meanings (confirmed from real DRP XML analysis):
--   <MediaStartTime> = file's TC origin in SECONDS since midnight (e.g., 45274 = 12:34:34)
--   <In>             = source mark-in offset in TIMELINE FRAMES (the actual source_in)
--   <Start>          = timeline position (frames)
--   <Duration>       = timeline duration (frames)
--
-- Bug: parse_resolve_tracks used MediaStartTime for source_in. This is wrong —
-- MediaStartTime is the file's TC origin, not a per-clip offset. The <In> element
-- holds the actual mark-in point within the source file.
--
-- Evidence: Camera clips (each a separate file) all had source_in=23 (wrong) instead
-- of 0 (correct — untrimmed clips). Audio clips all had the same source_in=45845
-- (the WAV file's TC origin) instead of varying per-clip offsets.

require("test_env")

print("=== test_drp_video_source_units.lua ===")

local drp_importer = require("importers.drp_importer")

-- Helper: construct a mock XML element
local function elem(tag, text, children)
    return {
        tag = tag,
        attrs = {},
        children = children or {},
        text = text or "",
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
-- Test 1: Video clip with empty <In/> → source_in = 0 (untrimmed)
--------------------------------------------------------------------------------

print("\n--- Test 1: Video untrimmed clip (In empty) → source_in=0 ---")

local seq_elem = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),  -- 0 = VIDEO
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "test_video_clip"),
                elem("Start", "86400"),
                elem("Duration", "1496"),
                elem("MediaStartTime", "45274"),  -- 12:34:34 in seconds (file TC origin)
                elem("In", ""),                    -- empty = untrimmed, start at file beginning
                elem("MediaFilePath", "/test/C095.mov"),
            })
        ),
    }),
})

local video_tracks, _ = drp_importer.parse_resolve_tracks(seq_elem, 24)

assert(#video_tracks == 1, "Expected 1 video track, got " .. #video_tracks)
assert(#video_tracks[1].clips == 1, "Expected 1 video clip")

local clip = video_tracks[1].clips[1]

-- Core assertion: source_in should be 0 (untrimmed clip, starts at file beginning)
-- NOT 23 (which was the buggy conversion of MediaStartTime 45274 * 24 / 48000)
assert(clip.source_in == 0, string.format(
    "Untrimmed video source_in should be 0, got %d", clip.source_in))
print("  ✓ Video source_in = 0 (untrimmed)")

-- source_out = source_in + duration (both in video frames)
assert(clip.source_out == 1496, string.format(
    "Video source_out should be 1496, got %d", clip.source_out))
print("  ✓ Video source_out = 1496")

--------------------------------------------------------------------------------
-- Test 2: Video clip with <In> offset → source_in = In value (trimmed)
--------------------------------------------------------------------------------

print("\n--- Test 2: Video trimmed clip (In=100) → source_in=100 ---")

local seq_trim = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "trimmed_video"),
                elem("Start", "86400"),
                elem("Duration", "200"),
                elem("MediaStartTime", "45274"),
                elem("In", "100"),  -- starts 100 frames into the file
                elem("MediaFilePath", "/test/C095.mov"),
            })
        ),
    }),
})

local v_trim = drp_importer.parse_resolve_tracks(seq_trim, 24)
local trim_clip = v_trim[1].clips[1]

assert(trim_clip.source_in == 100, string.format(
    "Trimmed video source_in should be 100, got %d", trim_clip.source_in))
print("  ✓ Video source_in = 100 (trimmed)")

assert(trim_clip.source_out == 300, string.format(
    "Trimmed video source_out should be 300 (100+200), got %d", trim_clip.source_out))
print("  ✓ Video source_out = 300")

--------------------------------------------------------------------------------
-- Test 3: Audio clip with empty <In/> → source_in = 0 (in samples)
--------------------------------------------------------------------------------

print("\n--- Test 3: Audio untrimmed clip → source_in=0 ---")

local seq_audio = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "1"),  -- 1 = AUDIO
        wrap_clips(
            elem("Sm2TiAudioClip", "", {
                elem("Name", "test_audio.WAV"),
                elem("Start", "86400"),
                elem("Duration", "73794"),        -- timeline frames
                elem("MediaStartTime", "45845"),  -- file TC origin (12:44:05 seconds)
                elem("In", ""),                    -- empty = start at file beginning
                elem("MediaFilePath", "/test/audio.wav"),
            })
        ),
    }),
})

local _, a_tracks = drp_importer.parse_resolve_tracks(seq_audio, 24)

assert(#a_tracks == 1, "Expected 1 audio track, got " .. #a_tracks)
local audio_clip = a_tracks[1].clips[1]

-- Audio source_in should be 0 (start of file), not 45845
assert(audio_clip.source_in == 0, string.format(
    "Untrimmed audio source_in should be 0, got %d", audio_clip.source_in))
print("  ✓ Audio source_in = 0 (untrimmed)")

-- Domain: 73794 timeline frames at 24fps = 3074.75 seconds
-- At 48000Hz: 3074.75 × 48000 = 147,588,000 audio samples
local expected_source_dur = 147588000
assert(audio_clip.source_out == expected_source_dur, string.format(
    "Audio source_out should be %d (73794 frames × 48000/24), got %d",
    expected_source_dur, audio_clip.source_out))
print("  ✓ Audio source_out = " .. expected_source_dur)

--------------------------------------------------------------------------------
-- Test 4: Audio clip with <In> offset → source_in in samples
--------------------------------------------------------------------------------

print("\n--- Test 4: Audio trimmed clip (In=73794 timeline frames) → source_in in samples ---")

local seq_audio_trim = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "1"),
        wrap_clips(
            elem("Sm2TiAudioClip", "", {
                elem("Name", "test_audio.WAV"),
                elem("Start", "160194"),
                elem("Duration", "30867"),
                elem("MediaStartTime", "45845"),
                elem("In", "73794"),  -- 73794 timeline frames into the audio file
                elem("MediaFilePath", "/test/audio.wav"),
            })
        ),
    }),
})

local _, a_trim = drp_importer.parse_resolve_tracks(seq_audio_trim, 24)
local audio_trim_clip = a_trim[1].clips[1]

-- Domain: In=73794 timeline frames at 24fps = 3074.75s → 147,588,000 samples at 48kHz
local expected_audio_in = 147588000
assert(audio_trim_clip.source_in == expected_audio_in, string.format(
    "Trimmed audio source_in should be %d samples (73794 × 48000/24), got %d",
    expected_audio_in, audio_trim_clip.source_in))
print("  ✓ Audio source_in = " .. expected_audio_in .. " samples")

--------------------------------------------------------------------------------
-- Test 5: MediaStartTime NOT used for source_in (regression guard)
--------------------------------------------------------------------------------

print("\n--- Test 5: Different MediaStartTime, same In → same source_in ---")

-- Two clips with different MediaStartTime but same In=0 should both get source_in=0
local seq_regression = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "clip_a"),
                elem("Start", "86400"),
                elem("Duration", "100"),
                elem("MediaStartTime", "45274"),  -- TC 12:34:34
                elem("In", ""),
                elem("MediaFilePath", "/test/a.mov"),
            }),
            elem("Sm2TiVideoClip", "", {
                elem("Name", "clip_b"),
                elem("Start", "86500"),
                elem("Duration", "100"),
                elem("MediaStartTime", "99999"),  -- completely different TC
                elem("In", ""),
                elem("MediaFilePath", "/test/b.mov"),
            })
        ),
    }),
})

local v_reg = drp_importer.parse_resolve_tracks(seq_regression, 24)
assert(v_reg[1].clips[1].source_in == 0, "clip_a source_in should be 0")
assert(v_reg[1].clips[2].source_in == 0, "clip_b source_in should be 0")
print("  ✓ Different MediaStartTime → both source_in=0 (MediaStartTime not used)")

---------------------------------------------------------------------------------
-- Test 6: MediaStartTime flows to clip struct + media_lookup
---------------------------------------------------------------------------------

print("\n--- Test 6: MediaStartTime stored on clip and media_lookup ---")

local seq_mst = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "clip_with_mst"),
                elem("Start", "86400"),
                elem("Duration", "200"),
                elem("MediaStartTime", "45274.12"),  -- 12:34:34 + fractional
                elem("In", ""),
                elem("MediaFilePath", "/test/mst_test.mov"),
            })
        ),
    })
})

local v_mst, _, media_map = drp_importer.parse_resolve_tracks(seq_mst, 25)
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

-- Verify conversion to frames: 45274.12 * 25 = 1131853 frames at 25fps
local expected_frames = math.floor(45274.12 * 25 + 0.5)
assert(expected_frames == 1131853, "expected 1131853 frames, got " .. expected_frames)
print("  ✓ 45274.12s * 25fps = 1131853 frames (for metadata storage)")

-- Zero MediaStartTime should also be stored (not nil)
local seq_zero_mst = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "clip_zero_mst"),
                elem("Start", "0"),
                elem("Duration", "100"),
                elem("MediaStartTime", "0"),
                elem("In", ""),
                elem("MediaFilePath", "/test/zero_mst.mov"),
            })
        ),
    })
})

local v_zmst, _, media_map_z = drp_importer.parse_resolve_tracks(seq_zero_mst, 25)
assert(v_zmst[1].clips[1].media_start_time == 0,
    "zero MediaStartTime should be stored as 0, not nil")
assert(media_map_z["/test/zero_mst.mov"].media_start_time == 0,
    "zero MediaStartTime in media_lookup should be 0")
print("  ✓ Zero MediaStartTime stored as 0 (not nil)")

print("\n✅ test_drp_video_source_units.lua passed")
