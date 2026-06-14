#!/usr/bin/env luajit
-- Regression: a video-only Resolve media item (e.g. a VFX render) whose
-- Sm2MpVideoClip FieldsBlob uses the SHORT UNCOMPRESSED variant must decode
-- cleanly and yield zero synced-audio references — not be reported as a
-- decode failure.
--
-- Resolve writes the FieldsBlob wrapper byte 9 as a variant tag:
--   0x81 = zstd-compressed Fields payload (carries the MediaRef audio list)
--   0x80 = short uncompressed Fields payload (video-only media; no audio refs)
-- Both share the 9-byte [BE32 version][BE32 size][marker] wrapper; the Fields
-- payload starts at byte 10. The decoder originally accepted only 0x81 and
-- logged a WARN ("FieldsBlob decode failed ... byte 9 must be 0x81, got 0x80")
-- for every 0x80 blob, even though nothing was actually lost.
--
-- The bytes below are a real 0x80 FieldsBlob captured from
-- tests/fixtures/resolve/anamnesis joe edit.drp (a VFX render pool clip).
-- Header decodes as version=2, declared_size=41, marker=0x80; the 40-byte
-- payload is an uncompressed protobuf with no embedded MediaRef UUID.

require("test_env")
print("=== test_fieldsblob_uncompressed_variant.lua ===")

local drp_binary = require("importers.drp_binary")

-- Real 0x80 blob from the anamnesis fixture (49 bytes / 98 hex chars).
local UNCOMPRESSED_HEX =
    "0000000200000029800a260a0a0a080a0610c6c1b38b0d12100000000000000005ffffffffffffffff18a6cec398d3ae07"

-- 1. The short uncompressed variant decodes without error.
local payload, err = drp_binary.decode_fields_blob(UNCOMPRESSED_HEX)
assert(payload, "0x80 (uncompressed) FieldsBlob must decode, got error: " .. tostring(err))
assert(err == nil, "decode of a valid 0x80 blob must not return an error: " .. tostring(err))

-- 2. The payload is the bytes after the 9-byte wrapper (49 - 9 = 40 bytes).
assert(#payload == 40, string.format(
    "uncompressed payload should be the 40 bytes after the wrapper, got %d", #payload))

-- 3. A video-only render carries no synced-audio MediaRefs.
local refs = drp_binary.extract_media_refs(payload)
assert(type(refs) == "table" and #refs == 0, string.format(
    "video-only render must yield zero synced-audio refs, got %d", #refs))

-- 4. A genuinely unknown wrapper marker still fails loudly (byte 9 = 0x7f).
local unknown_hex = "000000020000002" .. "9" .. "7f"
    .. UNCOMPRESSED_HEX:sub(19)  -- keep the same payload, only the marker differs
local bad, bad_err = drp_binary.decode_fields_blob(unknown_hex)
assert(bad == nil, "an unknown wrapper marker must NOT decode")
assert(bad_err and bad_err:find("0x7f"), string.format(
    "unknown-marker error must name the offending byte, got: %s", tostring(bad_err)))

print("✅ test_fieldsblob_uncompressed_variant.lua passed")
