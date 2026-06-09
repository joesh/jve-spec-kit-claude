require("test_env")

local drp = require("importers.drp_importer")

-- ===========================================================================
-- decode_bt_clip_path: extract original source path from BtVideoInfo/BtAudioInfo
-- binary blobs in DaVinci Resolve .drp MediaPool master clips
-- ===========================================================================

-- Test 1: Video clip blob (ProRes 4444, A001_05191238_C001.mov)
local video_hex = "00000002000000af8128b52ffd20b42d0500d4090a292f566f6c756d65732f416e616d4261636b34204a6f652f466f6f746167652f44617920312f413030311216413030315f30353139313233385f433030312e6d6f761a18547565204d61792031392030353a33383a313920323032302a0461703468323a2437663133336564622d363634352d343863332d393763362d38313266356230306139653868c089fceef8bfe902780480016490018080010100e4ae5514"
local expected_video = "/Volumes/AnamBack4 Joe/Footage/Day 1/A001/A001_05191238_C001.mov"
local result = drp.decode_bt_clip_path(video_hex)
assert(result == expected_video, string.format(
    "Video blob: expected '%s', got '%s'", expected_video, tostring(result)))
print("  ✓ Video clip blob → original path")

-- Test 2: Embedded audio blob (Linear PCM from same video file)
local embedded_audio_hex = "00000002000000868128b52ffd207ce103000a292f566f6c756d65732f416e616d4261636b34204a6f652f466f6f746167652f44617920312f413030311216413030315f30353139313233385f433030312e6d6f761a18547565204d61792031392030353a33383a313920323032302a0a4c696e6561722050434d68c089fceef8bfe90278048001649001808001"
local expected_audio = "/Volumes/AnamBack4 Joe/Footage/Day 1/A001/A001_05191238_C001.mov"
result = drp.decode_bt_clip_path(embedded_audio_hex)
assert(result == expected_audio, string.format(
    "Embedded audio blob: expected '%s', got '%s'", expected_audio, tostring(result)))
print("  ✓ Embedded audio blob → same original path as video")

-- Test 3: Standalone audio clip (S002-T003.WAV, separate recorder)
local standalone_audio_hex = "00000002000000898128b52ffd207ff903000a352f566f6c756d65732f416e616d4261636b34204a6f652f466f6f746167652f44617920312f446179203120536f756e642f44415931120d533030322d543030332e5741561a18536174204f63742031372030323a32333a323620323032302a0a4c696e6561722050434d6880c79ac2a6bbec0278048001649001808002"
local expected_standalone = "/Volumes/AnamBack4 Joe/Footage/Day 1/Day 1 Sound/DAY1/S002-T003.WAV"
result = drp.decode_bt_clip_path(standalone_audio_hex)
assert(result == expected_standalone, string.format(
    "Standalone audio: expected '%s', got '%s'", expected_standalone, tostring(result)))
print("  ✓ Standalone audio blob → correct path")

-- Test 4: Edge cases → nil (no crash)
assert(drp.decode_bt_clip_path(nil) == nil, "nil → nil")
assert(drp.decode_bt_clip_path("") == nil, "empty → nil")
assert(drp.decode_bt_clip_path("0000") == nil, "short → nil")
print("  ✓ Edge cases (nil/empty/short) → nil")

-- Test 5: Garbage data → nil (graceful, no crash)
local garbage = "00000002000000ff8128b52ffd20b42d0500140055555555555555555555"
assert(drp.decode_bt_clip_path(garbage) == nil, "garbage → nil")
print("  ✓ Garbage input → nil")

-- Test 6: Synthetic video blob (minimal, hand-crafted)
-- header(8) + marker(2) + id(8) + video_prefix(2) + F1("/tmp", 4B) + F2("a.mov", 5B)
local synthetic_video = "0000000200000019812800000000000000001400" ..
    "0a04" .. -- F1 tag + len=4
    "2f746d70" .. -- "/tmp"
    "1205" .. -- F2 tag + len=5
    "612e6d6f76" -- "a.mov"
result = drp.decode_bt_clip_path(synthetic_video)
assert(result == "/tmp/a.mov", string.format(
    "Synthetic video: expected '/tmp/a.mov', got '%s'", tostring(result)))
print("  ✓ Synthetic video blob")

-- Test 7: Synthetic audio blob (minimal, no video prefix)
-- header(8) + marker(2) + id(8) + F1("/tmp", 4B) + F2("a.mov", 5B)
local synthetic_audio = "000000020000001781280000000000000000" ..
    "0a04" .. -- F1 tag + len=4 (byte at offset 18 IS 0x0a → audio)
    "2f746d70" .. -- "/tmp"
    "1205" .. -- F2 tag + len=5
    "612e6d6f76" -- "a.mov"
result = drp.decode_bt_clip_path(synthetic_audio)
assert(result == "/tmp/a.mov", string.format(
    "Synthetic audio: expected '/tmp/a.mov', got '%s'", tostring(result)))
print("  ✓ Synthetic audio blob")

-- Test 8: Odd-length hex → nil (not silent corruption)
assert(drp.decode_bt_clip_path("0000000200000019812800000000000000001400" ..
    "0a042f746d701205612e6d6f760") == nil, "odd-length hex → nil")
print("  ✓ Odd-length hex → nil")

-- Test 9: Truncated blob (valid header, protobuf cut short)
local truncated = "0000000200000019812800000000000000001400" ..
    "0a042f746d70"  -- F1 present but F2 missing entirely
assert(drp.decode_bt_clip_path(truncated) == nil, "truncated blob → nil")
print("  ✓ Truncated blob (missing F2) → nil")

-- Test 10: Zero-length directory (F1 len=0)
local empty_dir = "0000000200000015812800000000000000001400" ..
    "0a00" .. -- F1 tag + len=0 (empty directory)
    "1205" .. -- F2 tag + len=5
    "612e6d6f76" -- "a.mov"
assert(drp.decode_bt_clip_path(empty_dir) == nil, "empty directory → nil")
print("  ✓ Empty directory → nil")

-- Test 11: Zero-length filename (F2 len=0)
local empty_fname = "0000000200000014812800000000000000001400" ..
    "0a042f746d70" .. -- F1: "/tmp"
    "1200" -- F2 tag + len=0 (empty filename)
assert(drp.decode_bt_clip_path(empty_fname) == nil, "empty filename → nil")
print("  ✓ Empty filename → nil")

-- Test 12: Runaway varint (all continuation bytes, never terminates)
local runaway = "00000002000000ff812800000000000000001400" ..
    "0affffffffffffffffffff" -- F1 length varint never terminates
assert(drp.decode_bt_clip_path(runaway) == nil, "runaway varint → nil")
print("  ✓ Runaway varint → nil")

-- Test 13: Garbled filename with control chars → nil
-- Filename "a.mp4\x1a\x18X" — \x1a is a control char (protobuf field tag leak)
local garbled_fname = "0000000200000020812800000000000000001400" ..
    "0a04" .. -- F1 tag + len=4
    "2f746d70" .. -- "/tmp"
    "120a" .. -- F2 tag + len=10
    "612e6d7034" .. -- "a.mp4"
    "1a18" .. -- \x1a\x18 — garbled protobuf leak
    "585858" -- "XXX"
result = drp.decode_bt_clip_path(garbled_fname)
assert(result == nil, string.format(
    "Garbled filename (control chars) should return nil, got '%s'", tostring(result)))
print("  ✓ Garbled filename with control chars → nil")

-- Test 14: Filename with null byte → nil
local null_fname = "000000020000001c812800000000000000001400" ..
    "0a04" .. -- F1 tag + len=4
    "2f746d70" .. -- "/tmp"
    "1206" .. -- F2 tag + len=6
    "6100" .. -- "a\0"
    "2e6d6f76" -- ".mov"
result = drp.decode_bt_clip_path(null_fname)
assert(result == nil, string.format(
    "Null byte in filename should return nil, got '%s'", tostring(result)))
print("  ✓ Filename with null byte → nil")

-- Test 15: Garbled directory with control chars → nil
-- Directory "/tmp\x01bad" — \x01 is a control char
local garbled_dir = "00000002000000198128000000000000000014000a08" ..
    "2f746d7001626164" .. -- "/tmp\x01bad" (8 bytes)
    "1205" .. -- F2 tag + len=5
    "612e6d6f76" -- "a.mov"
result = drp.decode_bt_clip_path(garbled_dir)
assert(result == nil, string.format(
    "Garbled directory (control chars) should return nil, got '%s'", tostring(result)))
print("  ✓ Garbled directory with control chars → nil")

print("✅ test_drp_blob_decode.lua passed")
