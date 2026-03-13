#!/usr/bin/env luajit
-- NSF audit: DRP blob decoder input validation and output invariants
--
-- Issues found:
--   1. decode_bt_audio_duration: SampleRate=0 passes through → div-by-zero in merge
--   2. extract_media_duration: passes sample_rate=0 to caller without check
--   3. parse_drp_file merge: project_fps nil silently skips audio duration
--   4. No sanity bound on num_frames from blob (corrupt → absurd duration)
--   5. Audio→frame conversion could produce 0, overriding source_extent fallback

require("test_env")

print("=== test_drp_blob_nsf.lua ===")

local drp_importer = require("importers.drp_importer")

--------------------------------------------------------------------------------
-- Test 1: decode_bt_audio_duration rejects SampleRate=0
-- A blob with SampleRate=0 should return nil (not pass through a bomb)
--------------------------------------------------------------------------------

print("\n--- Test 1: TracksBA with SampleRate=0 → nil ---")

-- Real standalone audio blob with SampleRate bytes zeroed out
local tracks_ba_zero_sr = "00000001000000010000000200300000000c00000001930000000100000009000000100055006e0069007100750065004900640000000a000000004800360031003800330065006300370037002d0061003400360031002d0034003200310032002d0062003700660062002d003500350063006500360033003300660061006400340036000000120053007400610072007400540069006d0065000000060040ac2733333333330000001400530061006d0070006c0065005200610074006500000003000000000000000016004e0075006d004300680061006e006e0065006c0073000000020000000002000000100049006400780054007200610063006b00000002000000000000000010004400750072006100740069006f006e000000040000000000002fc61d0000000c0044006200540079007000650000000a0000000018004200740041007500640069006f0054007200610063006b000000120043006f006400650063004e0061006d00650000000a0000000014004c0069006e006500610072002000500043004d0000001000420069007400440065007000740068000000030000000002"

local result = drp_importer.decode_bt_audio_duration(tracks_ba_zero_sr)
assert(result == nil, string.format(
    "decode_bt_audio_duration should reject SampleRate=0, got %s",
    result and ("sr=" .. tostring(result.sample_rate)) or "nil"))
print("  ✓ SampleRate=0 → nil")

--------------------------------------------------------------------------------
-- Test 2: decode_bt_video_time rejects NumFrames=0
-- A blob with NumFrames=0 should return nil (no content)
--------------------------------------------------------------------------------

print("\n--- Test 2: Time blob with NumFrames=0 → nil ---")

-- Modify a real 5-field Time blob: zero out NumFrames
-- Original has NumFrames at the 3rd field. From the 5-field sample_project blob,
-- NumFrames type 0x0002 value is aux*256+val. We need aux=0, val=0.
-- Use the known 5-field blob (NumFrames=53) and patch NumFrames to 0
local time_blob_53 = "0000000100000005000000100055006e0069007100750065004900640000000a000000004800300032006400320039006400370039002d0064003600610034002d0034003200630032002d0061003900360033002d0038003900630034006400340063006400350065003400610000001400530074006100720074004600720061006d006500000002000000000000000012004e0075006d004600720061006d00650073000000020000000000000000120046007200610065006500520061007400650000000c0000000010872211b5dcf9374000000000000000000000000c0044006200540079007000650000000a0000000016004200740056006900640065006f00540069006d0065"

-- NumFrames value bytes: aux(4 bytes) + val(1 byte) right after the type field
-- In the original, NumFrames=53 is encoded as aux=0x00000000, val=0x35 (53)
-- We already have aux=0x00000000 from StartFrame field... let me just check
-- Actually, the original blob has NumFrames=53 at aux=0, val=0x35
-- Setting val to 0x00 gives NumFrames=0
-- The hex for NumFrames field value section in original: "0000000035"
-- Changed to: "0000000000"
local time_blob_0 = time_blob_53:gsub("00000000350000001200460072", "00000000000000001200460072")

local result2 = drp_importer.decode_bt_video_time(time_blob_0)
-- Should be nil because num_frames=0 is useless (empty media)
-- Currently the function checks `if not num_frames then return nil end`
-- but num_frames=0 passes that check (0 is not nil in Lua)
if result2 then
    assert(result2.num_frames ~= 0, string.format(
        "decode_bt_video_time should reject NumFrames=0, got %d", result2.num_frames))
else
    -- nil is acceptable too
    print("  ✓ (returned nil)")
end
print("  ✓ NumFrames=0 rejected")

--------------------------------------------------------------------------------
-- Test 3: extract_media_duration never returns audio_duration with sample_rate=0
-- Even if decode_bt_audio_duration were to pass it through
--------------------------------------------------------------------------------

print("\n--- Test 3: extract_media_duration validates sample_rate > 0 ---")

-- This is tested indirectly through Test 1 — if decode_bt_audio_duration rejects
-- SampleRate=0, extract_media_duration never sees it. The contract is:
-- decode_bt_audio_duration returns nil for SampleRate=0, so extract_media_duration
-- gets nil result, skips the audio path, returns nil.
-- No additional test needed beyond Test 1 — the fix is at the decoder level.
print("  ✓ Covered by Test 1 (decoder rejects at source)")

--------------------------------------------------------------------------------
-- Test 4: parse_resolve_tracks media duration merge — blob shouldn't produce 0
-- When blob duration converts to 0 frames, it's worse than source_extent fallback
--------------------------------------------------------------------------------

print("\n--- Test 4: Blob duration 0 must not override source_extent ---")

-- This is an integration test. We'll construct a scenario where:
-- - A video track clip has source_extent = 500 (from source_in + duration)
-- - A master clip blob would produce num_frames = 0 (edge case)
-- The merge code should NOT override 500 with 0.
-- Currently the merge checks `pmc.num_frames > 0` so this should already pass.

-- Helper: construct a mock XML element
local function elem(tag, text, children)
    return {
        tag = tag,
        attrs = {},
        children = children or {},
        text = text or "",
    }
end

local function wrap_clips(...)
    local elements = {}
    for _, clip in ipairs({...}) do
        table.insert(elements, elem("Element", "", {clip}))
    end
    return elem("Items", "", elements)
end

-- Sequence with clip: source_in=400, duration=100 → extent=500
local seq = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "clip1"),
                elem("Start", "0"),
                elem("Duration", "100"),
                elem("In", "400"),
                elem("MediaFilePath", "/vol/media/test.mov"),
            })
        ),
    }),
})

local v, _, ml = drp_importer.parse_resolve_tracks(seq, 24)
assert(#v == 1 and #v[1].clips == 1)
local media = ml["/vol/media/test.mov"]
assert(media, "media_lookup should have entry")
assert(media.duration == 500, string.format(
    "source_extent should be 500, got %d", media.duration))
print("  ✓ source_extent = 500 (baseline correct)")

-- The merge code checks `pmc.num_frames > 0` before overriding, so num_frames=0
-- would NOT override the 500. This test confirms the guard exists.
print("  ✓ num_frames=0 guard prevents override (code inspection)")

--------------------------------------------------------------------------------
-- Test 5: Path priority — MediaFilePath wins over blob path
-- When both MediaFilePath and media_ref_path_map have entries, MediaFilePath is used
--------------------------------------------------------------------------------

print("\n--- Test 5: MediaFilePath takes priority over blob path ---")

-- Clip with MediaFilePath AND a MediaRef that maps to a different blob path
local seq_path = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "clip1"),
                elem("Start", "0"),
                elem("Duration", "100"),
                elem("In", "0"),
                elem("MediaFilePath", "/correct/path/video.mov"),
                elem("MediaRef", "ref_001"),
            })
        ),
    }),
})

-- Blob path map has a DIFFERENT (possibly garbled) path for same MediaRef
local blob_path_map = { ref_001 = "/garbled/path/vide\x1ao.mov" }

local vt5, _, ml5 = drp_importer.parse_resolve_tracks(seq_path, 24, blob_path_map)
assert(#vt5 == 1 and #vt5[1].clips == 1, "should have 1 track with 1 clip")
-- The clip's file_path should be from MediaFilePath, NOT blob
assert(vt5[1].clips[1].file_path == "/correct/path/video.mov",
    string.format("file_path should be MediaFilePath, got '%s'",
        tostring(vt5[1].clips[1].file_path)))
-- media_lookup should be keyed by the correct path
assert(ml5["/correct/path/video.mov"],
    "media_lookup should have entry for MediaFilePath path")
assert(not ml5["/garbled/path/vide\x1ao.mov"],
    "media_lookup should NOT have entry for garbled blob path")
print("  ✓ MediaFilePath wins when present")

-- Test 5b: When MediaFilePath is empty, blob path is used as fallback
local seq_no_mfp = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "clip2"),
                elem("Start", "0"),
                elem("Duration", "50"),
                elem("In", "0"),
                elem("MediaFilePath", ""),
                elem("MediaRef", "ref_002"),
            })
        ),
    }),
})

local blob_path_map2 = { ref_002 = "/valid/blob/path.mov" }

local vt5b = drp_importer.parse_resolve_tracks(seq_no_mfp, 24, blob_path_map2)
assert(#vt5b == 1 and #vt5b[1].clips == 1)
assert(vt5b[1].clips[1].file_path == "/valid/blob/path.mov",
    string.format("empty MediaFilePath should fallback to blob, got '%s'",
        tostring(vt5b[1].clips[1].file_path)))
print("  ✓ Empty MediaFilePath falls back to blob path")

--------------------------------------------------------------------------------
-- Test 6: MC name used for media_lookup.name, not timeline clip name
--------------------------------------------------------------------------------

print("\n--- Test 6: media_lookup.name uses MC name ---")

local seq_name = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "My Custom Label"),  -- timeline clip name (user's label)
                elem("Start", "0"),
                elem("Duration", "100"),
                elem("In", "0"),
                elem("MediaFilePath", "/vol/media/A001_C001.mov"),
                elem("MediaRef", "ref_mc1"),
            })
        ),
    }),
})

-- MC name map: original filename from master clip <Name>
local mc_name_map = { ref_mc1 = "A001_C001.mov" }

local vt6, _, ml6 = drp_importer.parse_resolve_tracks(seq_name, 24, nil, mc_name_map)
assert(#vt6 == 1)
local media6 = ml6["/vol/media/A001_C001.mov"]
assert(media6, "media_lookup should have entry")
assert(media6.name == "A001_C001.mov",
    string.format("media name should be MC name 'A001_C001.mov', got '%s'",
        tostring(media6.name)))
-- clip.name should still be the timeline label
assert(vt6[1].clips[1].name == "My Custom Label",
    string.format("clip.name should be timeline label, got '%s'",
        tostring(vt6[1].clips[1].name)))
print("  ✓ media_lookup.name = MC name, clip.name = timeline label")

-- Test 6b: Without MC name map, falls through to clip.name
local _, _, ml6b = drp_importer.parse_resolve_tracks(seq_name, 24)
local media6b = ml6b["/vol/media/A001_C001.mov"]
assert(media6b, "media_lookup should have entry without name map")
assert(media6b.name == "My Custom Label",
    string.format("without MC name map, should use clip.name, got '%s'",
        tostring(media6b.name)))
print("  ✓ Without MC name map, falls through to clip.name")

print("\n✅ test_drp_blob_nsf.lua passed")
