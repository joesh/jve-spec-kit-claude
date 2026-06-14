-- A DaVinci Resolve audio pool clip stores its source file path inside the
-- BtAudioInfo <Clip> binary blob. Dual-system external WAV clips (camera video
-- + separate sync audio) store that path with a directory-length field that
-- overruns the real directory into the trailing filename/date fields. The path
-- is nonetheless present verbatim in the blob; the decoder must recover the full
-- "<directory>/<filename>" for these clips, or every external WAV silently drops
-- out of the media pool (and the synced-audio linkage with it).
--
-- Both hex blobs below are REAL bytes lifted from
-- tests/fixtures/resolve/"anamnesis joe edit.drp". Expected paths are read
-- directly from the plaintext bytes in the blob — not derived from code.

require("test_env")

local drp_binary = require("importers.drp_binary")

print("=== test_drp_audio_clip_path_decode.lua ===")

-- ── Dual-system WAV: blob carries an overrunning directory-length field ──────
-- The path appears as plaintext: "/Users/joe/Local/Anamnesis/2026-02-28-mm/"
-- ".../Day 1 Sound/DAY1" then a 0x12 filename field "S002-T003.WAV".
local CORRUPT_WAV_HEX =
    "00000002000000bd8128b52ffd20ba9d0500740a0a702f55736572732f6a6f652f4c6f63616c2f"
 .. "416e616d6e657369732f323032362d30322d32382d6d6d2f61206a6f6520656469742f566f6c75"
 .. "6d65734261636b34204a6f652f466f6f746167652f446179203120536f756e642f44415931120d"
 .. "533030322d543030332e5741561a18536174204f63742031372030323a32333a32362032303230"
 .. "2a0a4c696e6561722050434d6880c79ac2a6bbec0278048001649001808002030053a6b5ea2e2e31cb"

local EXPECTED_WAV =
    "/Users/joe/Local/Anamnesis/2026-02-28-mm/a joe edit/VolumesBack4 Joe/"
 .. "Footage/Day 1 Sound/DAY1/S002-T003.WAV"

local got = drp_binary.decode_bt_clip_path(CORRUPT_WAV_HEX)
assert(got == EXPECTED_WAV, string.format(
    "dual-system WAV path not recovered:\n  expected: %s\n  got:      %s",
    EXPECTED_WAV, tostring(got)))
print("  ✓ dual-system WAV path recovered in full (dir + filename)")

-- ── Standard audio clip: directory length is well-formed (regression guard) ──
local GOOD_AUDIO_HEX =
    "00000002000000c58128b52ffd20bbd905000a502f566f6c756d65732f416e616d4261636b3420"
 .. "4a6f652f4f55545055542f46726f6d20536f756e6420506f73742f526f73732057696c6b65732d"
 .. "486f756768746f6e20536f756e64204d69782f4f6c64122e416e656d6e657369732046696e616c"
 .. "202d2053746572656f205072696e746d61737465722052585f30312e7761761a18546875204a61"
 .. "6e2020392031313a31383a303020323032352a0a4c696e6561722050434d6"
 .. "8f0c3fdbec1e88a0378028001649001808002"

local EXPECTED_GOOD =
    "/Volumes/AnamBack4 Joe/OUTPUT/From Sound Post/Ross Wilkes-Houghton Sound Mix/"
 .. "Old/Anemnesis Final - Stereo Printmaster RX_01.wav"

local got2 = drp_binary.decode_bt_clip_path(GOOD_AUDIO_HEX)
assert(got2 == EXPECTED_GOOD, string.format(
    "well-formed audio path regressed:\n  expected: %s\n  got:      %s",
    EXPECTED_GOOD, tostring(got2)))
print("  ✓ well-formed audio clip path still decodes (no regression)")

print("✅ test_drp_audio_clip_path_decode.lua passed")
