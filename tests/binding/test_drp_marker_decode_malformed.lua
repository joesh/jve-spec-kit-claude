-- test_drp_marker_decode_malformed.lua — corrupted-marker surfacing.
--
-- Domain: Sm2TiItemLockableBlob is a mixed container — only some entries are
-- markers (identified by the 0x81 wrapper marker byte). The decoder MUST
-- silently skip non-marker blobs (those scan-misses are normal), but a blob
-- that IDENTIFIES as a marker (0x81 wrapper present) and then fails to decode
-- MUST surface (rule 2.32 — no silent data loss).
--
-- Without this surfacing, a Resolve format drift would silently drop all
-- markers and we'd never know.
require("test_env")
local drp_binary = require("importers.drp_binary")

-- Helper: build a FieldsBlob hex with the given inner bytes (no zstd applied,
-- raw bytes after the 0x81 marker — guaranteed to fail zstd decompress).
local function to_hex(bytes)
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function make_marker_shaped_blob(inner_marker_byte, post_byte_payload)
    -- Outer TLV: [BE32 ver=1][BE32 field_count=1] then one field named
    -- "BlobData" of type 0x000c with our inner blob as payload.
    -- This mirrors the encoder side just enough to satisfy unwrap_marker_blob's
    -- structural check; the zstd content is intentionally bogus.
    local name = "\0B\0l\0o\0b\0D\0a\0t\0a"            -- UTF-16BE "BlobData", 16 bytes
    local function be32(n)
        return string.char(
            math.floor(n / 16777216) % 256,
            math.floor(n / 65536) % 256,
            math.floor(n / 256) % 256,
            n % 256)
    end
    -- Inner: [BE32 ver=1][BE32 declared_size=0][marker_byte][payload...]
    local inner = be32(1) .. be32(#post_byte_payload) .. string.char(inner_marker_byte) .. post_byte_payload
    -- 0x000c TLV value: [BE32 aux][1 byte val] = payload_len; then the payload
    -- whose first 8 bytes are read as an LE double (so pad to >= 8).
    while #inner < 8 do inner = inner .. "\0" end
    local plen = #inner
    local aux = math.floor(plen / 256)
    local val = plen % 256
    local field = be32(#name) .. name .. "\0\0\0\012" .. be32(aux) .. string.char(val) .. inner
    --                                  ^^^^ BE16 sep=0, BE16 type=0x000c
    local outer = be32(1) .. be32(1) .. field   -- version=1, field_count=1
    return to_hex(outer)
end

-- Case 1: marker byte = 0x80 (NOT a marker blob — Resolve's other per-item
-- state uses 0x80). Decoder MUST silently skip — no error, returns nil.
local result, err = drp_binary.decode_clip_markers(make_marker_shaped_blob(0x80, "junk"))
assert(result == nil, "0x80 wrapper must return nil (not a marker)")
assert(err == nil, "0x80 wrapper must NOT surface an error (silent skip): " .. tostring(err))

-- Case 2: marker byte = 0x81 (IS a marker blob) but zstd payload is junk.
-- The decoder MUST return (nil, err) — surfacing the decompression failure
-- because we committed to "this is a marker blob" via the 0x81 marker byte.
local result2, err2 = drp_binary.decode_clip_markers(make_marker_shaped_blob(0x81, "not_a_valid_zstd_frame"))
assert(result2 == nil, "0x81 with bad zstd must return nil markers")
assert(err2 ~= nil and #err2 > 0,
    "0x81 with bad zstd MUST surface an error (committed to marker shape), got nil")
print("  ✓ 0x81 + bad zstd surfaced: " .. err2)

print("✅ test_drp_marker_decode_malformed.lua passed")
