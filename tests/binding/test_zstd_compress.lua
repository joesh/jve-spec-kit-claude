-- T005 — qt_zstd_compress binding round-trip (run via `jve --test`).
--
-- Black-box: compress real payloads, decompress with the existing
-- qt_zstd_decompress binding, assert the original bytes return. Needs the
-- C++ bindings, so it runs inside the JVE process, not the pure Lua harness.

assert(type(qt_zstd_compress) == "function",
    "qt_zstd_compress binding not registered")
assert(type(qt_zstd_decompress) == "function",
    "qt_zstd_decompress binding not registered")

local function roundtrip(label, payload)
    local frame, err = qt_zstd_compress(payload)
    assert(frame, "compress failed for " .. label .. ": " .. tostring(err))
    assert(#frame > 0, "compress produced empty frame for " .. label)
    local back, derr = qt_zstd_decompress(frame)
    assert(back, "decompress failed for " .. label .. ": " .. tostring(derr))
    assert(back == payload, string.format(
        "round-trip mismatch for %s: got %d bytes, want %d", label, #back, #payload))
    print(string.format("  ✓ %s (%d → %d bytes)", label, #payload, #frame))
end

-- 1. Highly compressible (repetitive) — frame should be much smaller.
roundtrip("repetitive", string.rep("ABCD", 4096))

-- 2. Binary payload with NUL bytes and the full byte range (not just text) —
--    FieldsBlob payloads are protobuf-ish binary, so NULs must survive.
do
    local bytes = {}
    for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
    roundtrip("full-byte-range", string.rep(table.concat(bytes), 8))
end

-- 3. A realistic FieldsBlob-shaped payload: UTF-16BE UUIDs (what
--    extract_media_refs scans for) embedded in binary noise.
do
    local uuid = "7f133edb-6645-48c3-97c6-812f5b00a9e8"
    local u16 = uuid:gsub(".", function(c) return "\0" .. c end)
    roundtrip("utf16be-uuids", "\1\2\0\0" .. u16 .. "\0\0" .. u16 .. "\255")
end

-- 4. Incompressible random-ish data (compress must still round-trip, even if
--    the frame grows): a pseudo-random byte sequence.
do
    local out, x = {}, 0x12345
    for _ = 1, 8000 do
        x = (x * 1103515245 + 12345) % 2147483648
        out[#out + 1] = string.char(x % 256)
    end
    roundtrip("incompressible", table.concat(out))
end

-- 5. Empty payload — boundary; must round-trip to empty.
roundtrip("empty", "")

print("✅ test_zstd_compress.lua passed")
