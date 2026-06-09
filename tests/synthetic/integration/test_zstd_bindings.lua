-- Integration test: qt_zstd_decompress C++ binding round-trip.
--
-- This is stage 1 of synced-clip support: every Resolve Sm2Mp*.FieldsBlob
-- is a zstd-framed payload (see zstd_bindings.cpp). Before the DRP
-- importer can read MediaRef pointers out of FieldsBlobs, the binding
-- has to produce correct bytes.
--
-- Run: ./build/bin/jve --test tests/synthetic/integration/test_zstd_bindings.lua

require("test_env")

print("=== test_zstd_bindings.lua ===")

assert(type(qt_zstd_decompress) == "function",
    "qt_zstd_decompress binding not registered — build didn't link the new binding")

local function hex_to_bytes(hex)
    local out = {}
    for i = 1, #hex, 2 do
        out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16))
    end
    return table.concat(out)
end

-- ─────────────────────────────────────────────────────────────────────
-- Round-trip: a known zstd frame round-trips to its pre-compression
-- payload byte-for-byte. Frame hex was produced with python zstandard.
-- ─────────────────────────────────────────────────────────────────────
local FRAME_HEX = "28b52ffd202a51010068656c6c6f20776f726c642c207a737464206465636f6d7072657373696f6e20697320776f726b696e67"
local EXPECTED = "hello world, zstd decompression is working"

local frame = hex_to_bytes(FRAME_HEX)
local decoded, err = qt_zstd_decompress(frame)
assert(decoded, "decompress returned nil: " .. tostring(err))
assert(decoded == EXPECTED, string.format(
    "round-trip mismatch: expected %q, got %q", EXPECTED, decoded))
print(string.format("  ✓ round-trip OK (%d→%d bytes)", #frame, #decoded))

-- ─────────────────────────────────────────────────────────────────────
-- Malformed frame surfaces as (nil, err) — not a silent empty string,
-- not a crash. The DRP importer needs the error to propagate up so the
-- failing blob's caller can include clip context in the log.
-- ─────────────────────────────────────────────────────────────────────
local bad = "\x00\x01\x02\x03not a zstd frame"
local d2, err2 = qt_zstd_decompress(bad)
assert(d2 == nil, "bad input must return nil")
assert(type(err2) == "string" and err2:match("zstd"),
    "error string must mention zstd, got: " .. tostring(err2))
print("  ✓ malformed frame → (nil, err)")

-- ─────────────────────────────────────────────────────────────────────
-- Empty string: not a valid zstd frame. Must error, not return "".
-- ─────────────────────────────────────────────────────────────────────
local d3, err3 = qt_zstd_decompress("")
assert(d3 == nil, "empty input must return nil")
assert(type(err3) == "string", "empty input must produce err string")
print("  ✓ empty input → (nil, err)")

-- ─────────────────────────────────────────────────────────────────────
-- Real Sm2MpVideoClip.FieldsBlob (synced) from the example DRP — slice
-- off Resolve's 9-byte wrapper ([BE32 version][BE32 size][0x81 marker])
-- before handing to the binding. Proves the decoder handles the actual
-- shape + size the importer will see in production.
-- ─────────────────────────────────────────────────────────────────────
local FIELDS_BLOB_HEX =
    "00000002000001ec81" ..  -- 9-byte wrapper: version=2, size=492, marker=0x81
    "28b52ffd606e090d0f00369a4f3c30ada639200d97bfebaa6ff411469440681c513de70b81f" ..
    "87a4586ae22fa95dd67fd476b87de75ad1808a0316e7fab51f987833ec260b55760247ba748" ..
    "00370037000b6247455f911a33271dad7094e5c805ccf400bf52c7f8740e8703164ef432d24" ..
    "bcb860595140455e542251f675595e772251fe740086408d8400244870d86c680865342c349" ..
    "a109235f942b11321fba6904c890095148b12743352e3294e44696d8e720e7357f53621fccb" ..
    "ea22a43330e220942b1e2c26fdeb294f42d7519a993a52b5f054b47436e5c8a36f0cc66558f" ..
    "5a514fe7d575be5693d6ce4facc78e9d6ed6ead1a4fb7965a07d21243831a0c54bdf965a6dd" ..
    "bb66ddbb66d17cf984ea894eac78e1fb5d517ebbe59cdca11dbb95a59932cf6aab556330c15" ..
    "55600269a01813225484c840e1ca971202887194060f2ed5e4a13832309315412090020966e" ..
    "8a61ed04981f4b300008d041cc1d0ec86a12eecdf708b40c44c6037d27f1bbebff0fd3fc409" ..
    "63201fc4b882332413a461d04af762821c90be66c6ebcb82d29823cac804e554500621381788" ..
    "ca702410f5c0e1b8d594d561b3bbe39ef84a4e0044abd5656823fae61d6efaa7e285268ac586" ..
    "db8d0c5118cebbc3c6700d2748c4513cb355e4803dd7bbe1994b48f07eb8db00da017a218b66c60c"
local blob_bytes = hex_to_bytes(FIELDS_BLOB_HEX)
local frame_bytes = blob_bytes:sub(10)  -- skip 9-byte wrapper
local fb_decoded, fb_err = qt_zstd_decompress(frame_bytes)
assert(fb_decoded, "FieldsBlob decompress failed: " .. tostring(fb_err))
-- We know the decompressed payload is 2670 bytes and contains the synced
-- clip's name and the external-audio BtAudioInfo UUID in UTF-16BE.
assert(#fb_decoded == 2670, string.format(
    "FieldsBlob decompressed size: expected 2670, got %d", #fb_decoded))
assert(fb_decoded:find("A008_05211408_C011.mov synced", 1, true),
    "decompressed payload should contain the clip name")
-- UTF-16BE of "580b74c0" (first 8 chars of the external WAV's BtAudioInfo DbId)
local uuid_prefix_utf16be = "\0" .. "5" .. "\0" .. "8" .. "\0" .. "0" .. "\0" .. "b" .. "\0" .. "7" .. "\0" .. "4" .. "\0" .. "c" .. "\0" .. "0"
assert(fb_decoded:find(uuid_prefix_utf16be, 1, true),
    "decompressed payload should contain the external-audio UUID (UTF-16BE)")
print(string.format("  ✓ real FieldsBlob decompressed (%d→%d bytes, external-audio UUID present)",
    #frame_bytes, #fb_decoded))

print("\n✅ test_zstd_bindings.lua passed")
