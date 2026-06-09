-- Test: DRP dual timecode extraction (file_original_timecode)
--
-- Verifies:
-- 1. decode_bt_audio_duration extracts StartTime from TracksBA blob
-- 2. The extracted StartTime can be compared against start_tc_value
--    to detect a Set Timecode override
-- 3. When override exists: file_original_timecode ≠ start_tc_value
-- 4. When no override: file_original_timecode = start_tc_value → not stored
--
-- Uses raw hex from the two-clips-same-file-different-tc.drp fixture:
--   Clip 1 (override):     Time.Timecode = "13:16:12:21" → start_tc_value = 1194321
--   Clip 2 (no override):  Time.Timecode = "00:07:35:08" → start_tc_value = 11383
--   Both:                  TracksBA.StartTime ≈ 455.32s   → file_tc = 11383 at 25fps

require("test_env")
local drp = require("importers.drp_importer")

print("=== test_drp_dual_tc.lua ===")

-- TracksBA hex from Clip 1 (override master clip) in two-clips fixture
local CLIP1_TRACKS_BA = "00000001000000010000000200300000000c00000001930000000100000009000000100055006e0069007100750065004900640000000a000000004800360038003400640030006600370036002d0030003400660031002d0034006400340035002d0039003500350037002d003300340036003200390038006100630031006600650039000000120053007400610072007400540069006d00650000000600407c751eb851eb850000001400530061006d0070006c0065005200610074006500000003000000bb8000000016004e0075006d004300680061006e006e0065006c0073000000020000000002000000100049006400780054007200610063006b00000002000000000000000010004400750072006100740069006f006e000000040000000000009f7e000000000c0044006200540079007000650000000a0000000018004200740041007500640069006f0054007200610063006b000000120043006f006400650063004e0061006d00650000000a0000000014004c0069006e006500610072002000500043004d0000001000420069007400440065007000740068000000030000000001"

-- TracksBA hex from Clip 2 (non-override master clip) — same file, different UniqueId
local CLIP2_TRACKS_BA = "00000001000000010000000200300000000c00000001930000000100000009000000100055006e0069007100750065004900640000000a000000004800310031006300620035003000380036002d0062006400320030002d0034006400380064002d0039003500330037002d003600610062003800380037003300340030003200360062000000120053007400610072007400540069006d00650000000600407c751eb851eb850000001400530061006d0070006c0065005200610074006500000003000000bb8000000016004e0075006d004300680061006e006e0065006c0073000000020000000002000000100049006400780054007200610063006b00000002000000000000000010004400750072006100740069006f006e000000040000000000009f7e000000000c0044006200540079007000650000000a0000000018004200740041007500640069006f0054007200610063006b000000120043006f006400650063004e0061006d00650000000a0000000014004c0069006e006500610072002000500043004d0000001000420069007400440065007000740068000000030000000001"

-- ─────────────────────────────────────────────────────────────
-- Test 1: decode_bt_audio_duration extracts StartTime
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 1: TracksBA StartTime extraction ---")

local r1 = drp.decode_bt_audio_duration(CLIP1_TRACKS_BA)
assert(r1, "Clip 1 TracksBA decode failed")
assert(r1.duration_samples == 10452480, string.format(
    "Clip 1 duration_samples: expected 10452480, got %s", tostring(r1.duration_samples)))
assert(r1.sample_rate == 48000, string.format(
    "Clip 1 sample_rate: expected 48000, got %s", tostring(r1.sample_rate)))

-- This is the key new field — start_time_seconds from the StartTime TLV field.
-- 455.32 seconds = 00:07:35:08 at 25fps = the file's real container TC origin.
assert(r1.start_time_seconds ~= nil, "Clip 1 start_time_seconds must not be nil (T005 not implemented yet?)")
assert(math.abs(r1.start_time_seconds - 455.32) < 0.001, string.format(
    "Clip 1 start_time_seconds: expected ≈455.32, got %s", tostring(r1.start_time_seconds)))
print(string.format("  ✓ Clip 1 TracksBA.StartTime = %.4f seconds (00:07:35:08)", r1.start_time_seconds))

local r2 = drp.decode_bt_audio_duration(CLIP2_TRACKS_BA)
assert(r2, "Clip 2 TracksBA decode failed")
assert(r2.start_time_seconds ~= nil, "Clip 2 start_time_seconds must not be nil")
assert(math.abs(r2.start_time_seconds - 455.32) < 0.001, string.format(
    "Clip 2 start_time_seconds: expected ≈455.32 (same file), got %s", tostring(r2.start_time_seconds)))
print(string.format("  ✓ Clip 2 TracksBA.StartTime = %.4f seconds (same file → same value)", r2.start_time_seconds))

-- ─────────────────────────────────────────────────────────────
-- Test 2: File TC differs from override TC → store file_original_timecode
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 2: Override detection (file_original_timecode logic) ---")

local native_rate = 25  -- 25fps project
local audio_sr = 48000

-- Clip 1: override master clip
-- MediaStartTime would be 47772.84s (from Resolve's Time.Timecode "13:16:12:21")
-- start_tc_value = floor(47772.84 * 25 + 0.5) = 1194321
local clip1_mst = 47772.84  -- seconds since midnight for 13:16:12:21
local clip1_start_tc = math.floor(clip1_mst * native_rate + 0.5)
assert(clip1_start_tc == 1194321, string.format(
    "13:16:12:21 at 25fps should be 1194321, got %d", clip1_start_tc))

-- file_tc from TracksBA.StartTime
local clip1_file_tc = math.floor(r1.start_time_seconds * native_rate + 0.5)
assert(clip1_file_tc == 11383, string.format(
    "00:07:35:08 at 25fps should be 11383, got %d", clip1_file_tc))

-- Override detected: file_tc ≠ start_tc
assert(clip1_file_tc ~= clip1_start_tc,
    "Clip 1 must have file_tc ≠ start_tc (override present)")
print(string.format("  ✓ Clip 1 override: start_tc=%d (13:16:12:21) ≠ file_tc=%d (00:07:35:08)",
    clip1_start_tc, clip1_file_tc))

-- Clip 2: non-override master clip
-- MediaStartTime would be 455.32s (from Resolve's Time.Timecode "00:07:35:08")
-- start_tc_value = floor(455.32 * 25 + 0.5) = 11383
local clip2_mst = 455.32
local clip2_start_tc = math.floor(clip2_mst * native_rate + 0.5)
assert(clip2_start_tc == 11383, string.format(
    "00:07:35:08 at 25fps should be 11383, got %d", clip2_start_tc))

local clip2_file_tc = math.floor(r2.start_time_seconds * native_rate + 0.5)
assert(clip2_file_tc == clip2_start_tc,
    string.format("Clip 2 must have file_tc = start_tc (no override), got file_tc=%d start_tc=%d",
        clip2_file_tc, clip2_start_tc))
print(string.format("  ✓ Clip 2 no override: start_tc=%d = file_tc=%d (both 00:07:35:08)",
    clip2_start_tc, clip2_file_tc))

-- ─────────────────────────────────────────────────────────────
-- Test 3: Audio TC mirrors video TC
-- ─────────────────────────────────────────────────────────────
print("\n--- Test 3: Audio TC from TracksBA.StartTime ---")

local clip1_file_tc_audio = math.floor(r1.start_time_seconds * audio_sr + 0.5)
-- 455.32 * 48000 = 21855360
assert(clip1_file_tc_audio == 21855360, string.format(
    "Audio file_tc at 48kHz should be 21855360, got %d", clip1_file_tc_audio))
print(string.format("  ✓ Audio file_original_timecode = %d samples (455.32s × 48kHz)", clip1_file_tc_audio))

print("\n✅ test_drp_dual_tc.lua passed")
