#!/usr/bin/env luajit
-- TDD test: DRP TLV blob decoders for BtVideoInfo/Time and BtAudioInfo/TracksBA
--
-- These blobs encode authoritative media duration in MediaPool master clips.
-- Time blob → NumFrames (video frame count)
-- TracksBA blob → Duration (audio sample count) + SampleRate

require("test_env")

print("=== test_drp_time_blob_decode.lua ===")

local drp_importer = require("importers.drp_importer")

--------------------------------------------------------------------------------
-- Test 1: Decode 5-field Time blob (sample_project fixture, CrossGuateTL.mp4)
-- Fields: UniqueId, StartFrame=0, NumFrames=53, FrameRate=23.976, DbType
-- Raw hex extracted from fixture via sed
--------------------------------------------------------------------------------

print("\n--- Test 1: 5-field Time blob → NumFrames=53 ---")

-- Exact hex from sample_project.drp MediaPool/Master/001_Footage/MpFolder.xml (first Time blob)
local time_blob_5field = "0000000100000005000000100055006e0069007100750065004900640000000a000000004800300032006400320039006400370039002d0064003600610034002d0034003200630032002d0061003900360033002d0038003900630034006400340063006400350065003400610000001400530074006100720074004600720061006d006500000002000000000000000012004e0075006d004600720061006d0065007300000002000000003500000012004600720061006d006500520061007400650000000c0000000010872211b5dcf9374000000000000000000000000c0044006200540079007000650000000a0000000016004200740056006900640065006f00540069006d0065"

local result = drp_importer.decode_bt_video_time(time_blob_5field)
assert(result, "decode_bt_video_time should return non-nil for valid Time blob")
assert(result.num_frames == 53, string.format(
    "Expected NumFrames=53, got %s", tostring(result.num_frames)))
assert(result.unique_id == "02d29d79-d6a4-42c2-a963-89c4d4cd5e4a", string.format(
    "Expected UUID, got %s", tostring(result.unique_id)))
assert(math.abs(result.frame_rate - 23.976) < 0.01, string.format(
    "Expected FrameRate ~23.976, got %s", tostring(result.frame_rate)))
print("  ✓ 5-field Time blob: NumFrames=53, FrameRate=23.976")

--------------------------------------------------------------------------------
-- Test 2: Decode 5-field Time blob with large NumFrames
-- (sample_project fixture, A001_07232330_C004.mp4, NumFrames=2890)
-- aux=0x0000000b (11), val=0x4a (74) → 11*256+74 = 2890
--------------------------------------------------------------------------------

print("\n--- Test 2: 5-field Time blob → NumFrames=2890 ---")

-- Exact hex from fixture
local time_blob_2890 = "0000000100000005000000100055006e0069007100750065004900640000000a000000004800660066006300610064006300650064002d0035003000320061002d0034003600370064002d0062006600370036002d0036006300630065003500660031006500640030006500370000001400530074006100720074004600720061006d006500000002000000000000000012004e0075006d004600720061006d00650073000000020000000b4a00000012004600720061006d006500520061007400650000000c0000000010000000000000394000000000000000000000000c0044006200540079007000650000000a0000000016004200740056006900640065006f00540069006d0065"

local result2 = drp_importer.decode_bt_video_time(time_blob_2890)
assert(result2, "decode_bt_video_time should return non-nil")
assert(result2.num_frames == 2890, string.format(
    "Expected NumFrames=2890, got %s", tostring(result2.num_frames)))
assert(math.abs(result2.frame_rate - 25.0) < 0.01, string.format(
    "Expected FrameRate=25.0, got %s", tostring(result2.frame_rate)))
print("  ✓ 5-field Time blob: NumFrames=2890, FrameRate=25.0")

--------------------------------------------------------------------------------
-- Test 3: Decode 6-field Time blob (anamnesis fixture, has Timecode field)
-- Fields: UniqueId, Timecode, StartFrame=0, NumFrames=113671, FrameRate=25, DbType
-- NumFrames aux=0x0001bc (444), val=0x07 (7) → 444*256+7 = 113671
--------------------------------------------------------------------------------

print("\n--- Test 3: 6-field Time blob → NumFrames=113671 ---")

-- Exact hex from anamnesis fixture
local time_blob_6field = "0000000100000006000000100055006e0069007100750065004900640000000a000000004800300066003300650032003700370037002d0038003000610032002d0034003800360039002d0062006500330039002d0065006600310035003700310036003500620066006400650000001000540069006d00650063006f006400650000000a000000001600300030003a00350039003a00350030003a003000300000001400530074006100720074004600720061006d006500000002000000000000000012004e0075006d004600720061006d0065007300000002000001bc0700000012004600720061006d006500520061007400650000000c0000000010000000000000394000000000000000000000000c0044006200540079007000650000000a0000000016004200740056006900640065006f00540069006d0065"

local result3 = drp_importer.decode_bt_video_time(time_blob_6field)
assert(result3, "decode_bt_video_time should return non-nil for 6-field blob")
assert(result3.num_frames == 113671, string.format(
    "Expected NumFrames=113671, got %s", tostring(result3.num_frames)))
assert(math.abs(result3.frame_rate - 25.0) < 0.01, string.format(
    "Expected FrameRate=25.0, got %s", tostring(result3.frame_rate)))
print("  ✓ 6-field Time blob: NumFrames=113671, FrameRate=25.0")

--------------------------------------------------------------------------------
-- Test 4: Decode TracksBA blob (embedded audio from A001_07232330_C004.mp4)
-- Duration=5550080 samples, SampleRate=48000
--------------------------------------------------------------------------------

print("\n--- Test 4: TracksBA blob → Duration=5550080, SampleRate=48000 ---")

-- Exact hex from fixture
local tracks_ba_embedded = "00000001000000010000000200300000000c00000001ac000000010000000a000000100055006e0069007100750065004900640000000a000000004800380036006500620034003400350035002d0036003600310034002d0034003600350063002d0039006400380037002d003100380031006500330039003500610066003000660062000000120053007400610072007400540069006d0065000000060000000000000000000000001400530061006d0070006c0065005200610074006500000003000000bb8000000016004e0075006d004300680061006e006e0065006c0073000000020000000002000000100049006400780054007200610063006b00000002000000000000000010004400750072006100740069006f006e0000000400000000000054b0000000000c0044006200540079007000650000000a0000000018004200740041007500640069006f0054007200610063006b000000120043006f006400650063004e0061006d00650000000a00000000060041004100430000001a004300680061006e006e0065006c004c00610079006f007500740000000200000000020000001000420069007400440065007000740068000000030000000003"

local result4 = drp_importer.decode_bt_audio_duration(tracks_ba_embedded)
assert(result4, "decode_bt_audio_duration should return non-nil")
assert(result4.duration_samples == 5550080, string.format(
    "Expected Duration=5550080, got %s", tostring(result4.duration_samples)))
assert(result4.sample_rate == 48000, string.format(
    "Expected SampleRate=48000, got %s", tostring(result4.sample_rate)))
print("  ✓ TracksBA (embedded): Duration=5550080 samples, SampleRate=48000")

--------------------------------------------------------------------------------
-- Test 5: Decode TracksBA blob (standalone audio: APM_Adobe_Going Home_v3.wav)
-- Duration=3130909 samples, SampleRate=48000, 9 fields (no ChannelLayout)
--------------------------------------------------------------------------------

print("\n--- Test 5: TracksBA blob (standalone audio) → Duration=3130909 ---")

-- Exact hex from fixture
local tracks_ba_standalone = "00000001000000010000000200300000000c00000001930000000100000009000000100055006e0069007100750065004900640000000a000000004800360031003800330065006300370037002d0061003400360031002d0034003200310032002d0062003700660062002d003500350063006500360033003300660061006400340036000000120053007400610072007400540069006d0065000000060040ac2733333333330000001400530061006d0070006c0065005200610074006500000003000000bb8000000016004e0075006d004300680061006e006e0065006c0073000000020000000002000000100049006400780054007200610063006b00000002000000000000000010004400750072006100740069006f006e000000040000000000002fc61d0000000c0044006200540079007000650000000a0000000018004200740041007500640069006f0054007200610063006b000000120043006f006400650063004e0061006d00650000000a0000000014004c0069006e006500610072002000500043004d0000001000420069007400440065007000740068000000030000000002"

local result5 = drp_importer.decode_bt_audio_duration(tracks_ba_standalone)
assert(result5, "decode_bt_audio_duration should return non-nil for standalone audio")
assert(result5.duration_samples == 3130909, string.format(
    "Expected Duration=3130909, got %s", tostring(result5.duration_samples)))
assert(result5.sample_rate == 48000, string.format(
    "Expected SampleRate=48000, got %s", tostring(result5.sample_rate)))
print("  ✓ TracksBA (standalone): Duration=3130909 samples, SampleRate=48000")

--------------------------------------------------------------------------------
-- Test 6: Edge cases — nil/empty/truncated/garbage → nil
--------------------------------------------------------------------------------

print("\n--- Test 6: Edge cases → nil ---")

assert(drp_importer.decode_bt_video_time(nil) == nil, "nil input → nil")
assert(drp_importer.decode_bt_video_time("") == nil, "empty input → nil")
assert(drp_importer.decode_bt_video_time("0000") == nil, "truncated → nil")
assert(drp_importer.decode_bt_video_time("zzzzzzzzzzzzzzzzzzzzzzzz") == nil, "garbage → nil")
-- Valid header but truncated before fields
assert(drp_importer.decode_bt_video_time("0000000100000005") == nil, "header-only → nil")

assert(drp_importer.decode_bt_audio_duration(nil) == nil, "nil input → nil")
assert(drp_importer.decode_bt_audio_duration("") == nil, "empty input → nil")
assert(drp_importer.decode_bt_audio_duration("0000") == nil, "truncated → nil")
assert(drp_importer.decode_bt_audio_duration("zzzzzzzzzzzzzzzzzzzz") == nil, "garbage → nil")
print("  ✓ All edge cases return nil")

print("\n✅ test_drp_time_blob_decode.lua passed")
