#!/usr/bin/env luajit
-- Regression test: audio master clips whose filename has leading whitespace
-- must have that whitespace preserved in the imported media row's file_path.
--
-- Domain: POSIX filenames allow leading/trailing whitespace. An import path
-- whose basename differs from the on-disk basename (even by one space) fails
-- the relinker's filename match and the clip stays offline.
--
-- The bug this catches:
--   1. The XML parser trims leading/trailing whitespace from element text.
--   2. For audio master clips, the importer used to reconstruct the source
--      path as `blob_directory .. "/" .. xml_name` — where xml_name has the
--      leading space stripped by the XML parser.
--   3. The blob itself contains the correct filename with leading space.
--
-- Production case: ' Return 2 - Max Richter.mp3' in the anamnesis gold master.

require("test_env")

local drp_binary = require("importers.drp_binary")
local drp_importer = require("importers.drp_importer")

print("=== test_drp_filename_leading_space.lua ===")

-- extract_original_path is exported for regression testing.
assert(drp_importer.extract_original_path,
    "drp_importer.extract_original_path must be exported for regression testing")

local function elem(tag, text, children)
    return { tag = tag, attrs = {}, children = children or {}, text = text or "" }
end

-- ---------------------------------------------------------------------------
-- Case 1 — happy path: filename with leading space is preserved via the
-- blob's decoded full path. Real blob from the anamnesis gold master.
-- ---------------------------------------------------------------------------

local AUDIO_CLIP_BLOB_LEADING_SPACE =
    "00000002000000648128b52ffd205ad102000a2c2f55736572732f6a6f652f4c6f636" ..
    "16c2f416e616d6e657369732f4d757369632f54656d7020547261636b73121b205265" ..
    "7475726e2032202d204d617820526963687465722e6d70332a034d503378028001649" ..
    "001888002"

local EXPECTED_PATH_LEADING_SPACE =
    "/Users/joe/Local/Anamnesis/Music/Temp Tracks/ Return 2 - Max Richter.mp3"

-- Sanity: the blob decoder itself preserves the leading space.
local decoded_path = drp_binary.decode_bt_clip_path(AUDIO_CLIP_BLOB_LEADING_SPACE)
assert(decoded_path == EXPECTED_PATH_LEADING_SPACE, string.format(
    "blob decoder dropped characters: expected %q, got %q",
    EXPECTED_PATH_LEADING_SPACE, decoded_path or "<nil>"))
print("  ✓ blob decoder preserves leading space in filename")

-- Simulate what the C++ XML parser hands back: <Name>'s leading space is gone.
local xml_trimmed_name = "Return 2 - Max Richter.mp3"
assert(xml_trimmed_name ~= " Return 2 - Max Richter.mp3",
    "test setup: xml_trimmed_name should differ from the on-disk basename")

local clip_leading_space = elem("Sm2MpAudioClip", "", {
    elem("Name", xml_trimmed_name),
    elem("BtAudioInfo", "", {
        elem("Clip", AUDIO_CLIP_BLOB_LEADING_SPACE),
    }),
})

local path_leading_space = drp_importer.extract_original_path(clip_leading_space)
assert(path_leading_space == EXPECTED_PATH_LEADING_SPACE, string.format(
    "leading-space filename lost on import:\n" ..
    "  expected: %q\n" ..
    "  got:      %q",
    EXPECTED_PATH_LEADING_SPACE, path_leading_space or "<nil>"))
print(string.format("  ✓ import preserves leading space: %q", path_leading_space))

-- ---------------------------------------------------------------------------
-- Case 2 — backward-compat sanity: a plain filename (no leading whitespace)
-- still imports correctly. Regression guard for the fix.
-- ---------------------------------------------------------------------------

-- Build a blob for 'Return 2 - Max Richter.mp3' (no leading space). Same
-- directory, filename is 26 bytes instead of 27.
--
-- Blob format (audio, audio protobuf starts at byte offset 18/0-indexed):
--   prefix 18 bytes + 0x0a + varint(dir_len) + dir + 0x12 + varint(name_len) + name + suffix
-- We construct it inline as a hex string so the test doesn't depend on any
-- blob-construction helper.
local DIR_UTF8 = "/Users/joe/Local/Anamnesis/Music/Temp Tracks"
local PLAIN_FILENAME = "Return 2 - Max Richter.mp3"

-- Converts ASCII text to hex.
local function to_hex(str)
    return (str:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Protobuf prefix taken verbatim from the real production blob — identifies
-- this as an audio Clip blob with the protobuf starting at byte 18.
-- Audio blobs begin with 18 bytes ending in 0x02 before the 0x0a protobuf marker.
local PREFIX = "00000002000000648128b52ffd205ad10200"
local DIR_HEADER = "0a" .. string.format("%02x", #DIR_UTF8)  -- field 1, varint length (< 128)
local NAME_HEADER = "12" .. string.format("%02x", #PLAIN_FILENAME)  -- field 2
local SUFFIX = "2a034d503378028001649001888002"  -- codec field + trailing

local AUDIO_CLIP_BLOB_PLAIN = PREFIX
    .. DIR_HEADER .. to_hex(DIR_UTF8)
    .. NAME_HEADER .. to_hex(PLAIN_FILENAME)
    .. SUFFIX

local EXPECTED_PATH_PLAIN = DIR_UTF8 .. "/" .. PLAIN_FILENAME

local decoded_plain = drp_binary.decode_bt_clip_path(AUDIO_CLIP_BLOB_PLAIN)
assert(decoded_plain == EXPECTED_PATH_PLAIN, string.format(
    "plain filename blob test setup failed: decoder returned %q (expected %q)",
    decoded_plain or "<nil>", EXPECTED_PATH_PLAIN))

local clip_plain = elem("Sm2MpAudioClip", "", {
    elem("Name", PLAIN_FILENAME),
    elem("BtAudioInfo", "", {
        elem("Clip", AUDIO_CLIP_BLOB_PLAIN),
    }),
})
local path_plain = drp_importer.extract_original_path(clip_plain)
assert(path_plain == EXPECTED_PATH_PLAIN, string.format(
    "plain filename import regressed: expected %q, got %q",
    EXPECTED_PATH_PLAIN, path_plain or "<nil>"))
print(string.format("  ✓ plain filename unchanged: %q", path_plain))

-- ---------------------------------------------------------------------------
-- Case 3 — garbled blob filename (control characters): decoder returns nil
-- for the path but still returns the directory. Importer must fall back to
-- reconstructing from <Name>. This is the documented contract the audio
-- branch of extract_original_path depends on.
-- ---------------------------------------------------------------------------

-- Build a blob with a filename containing a control character (0x01), which
-- decode_bt_clip_path rejects as unreliable.
local GARBLED_FILENAME = "\x01garbage.wav"
local GARBLED_NAME_HEADER = "12" .. string.format("%02x", #GARBLED_FILENAME)
local AUDIO_CLIP_BLOB_GARBLED = PREFIX
    .. DIR_HEADER .. to_hex(DIR_UTF8)
    .. GARBLED_NAME_HEADER .. to_hex(GARBLED_FILENAME)
    .. SUFFIX

local decoded_garbled_path, decoded_garbled_dir =
    drp_binary.decode_bt_clip_path(AUDIO_CLIP_BLOB_GARBLED)
assert(decoded_garbled_path == nil,
    "garbled blob test setup: decoder should return nil path for control-char filename")
assert(decoded_garbled_dir == DIR_UTF8, string.format(
    "garbled blob test setup: decoder should still return directory (got %q)",
    decoded_garbled_dir or "<nil>"))

local NAME_FROM_XML = "clean-name-from-xml.wav"
local clip_garbled = elem("Sm2MpAudioClip", "", {
    elem("Name", NAME_FROM_XML),
    elem("BtAudioInfo", "", {
        elem("Clip", AUDIO_CLIP_BLOB_GARBLED),
    }),
})
local path_garbled_fallback = drp_importer.extract_original_path(clip_garbled)
local EXPECTED_GARBLED = DIR_UTF8 .. "/" .. NAME_FROM_XML
assert(path_garbled_fallback == EXPECTED_GARBLED, string.format(
    "garbled blob should fall back to XML <Name>: expected %q, got %q",
    EXPECTED_GARBLED, path_garbled_fallback or "<nil>"))
print(string.format("  ✓ garbled blob falls back to XML name: %q", path_garbled_fallback))

print("\n✅ test_drp_filename_leading_space.lua passed")
