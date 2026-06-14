-- Golden test: the reverse MediaTimemapBA encoder must reproduce the exact
-- byte structure DaVinci Resolve authors.
--
-- The reference blob is the real MediaTimemapBA from the reverse clip in the
-- Resolve-authored fixture "test audio, reverse audio.drp", extracted verbatim
-- to tests/fixtures/resolve/reverse_audio_mtba.hex. We decode it to recover its
-- (y_max, x_max, keyframes), re-encode with the same UniqueId, and assert the
-- encoder reproduces Resolve's bytes exactly. Byte-identity is the strongest
-- offline evidence the encoder emits a form Resolve will accept (it IS Resolve's
-- form). Final acceptance is the live VM round-trip.

require("test_env")
local enc = require("exporters.drt_binary")
local dec = require("importers.drp_binary")

print("=== test_drt_reverse_mtba_golden.lua ===")

-- The UniqueId Resolve minted for this curve (read from the blob's UniqueId field).
local FIXTURE_UUID = "e0e23d82-2c2f-4c5e-9c74-3ee34dd17792"

local script_dir = debug.getinfo(1, "S").source:match("@(.*/)")
assert(script_dir, "could not determine script dir")
local hex_path = script_dir .. "../../fixtures/resolve/reverse_audio_mtba.hex"
local f = assert(io.open(hex_path, "r"), "cannot open " .. hex_path)
local REV_HEX = (f:read("*a"):gsub("%s+", ""))   -- strip trailing newline/whitespace
f:close()
assert(#REV_HEX == 1320, "unexpected reference blob length: " .. #REV_HEX)

-- Sanity: the reference decodes as the reverse curve we expect.
local decoded = dec.decode_media_timemap(REV_HEX)
assert(decoded, "reference blob failed to decode")
assert(decoded.is_reverse == true, "reference must decode as reverse")
print(string.format("  reference: y_max=%.10f x_max=%.10f is_reverse=%s kf=%d",
    decoded.y_max, decoded.x_max, tostring(decoded.is_reverse), #decoded.keyframes))

-- Re-encode from the reference's own decoded values + its UniqueId.
local spec = {
    y_max = decoded.y_max,
    x_max = decoded.x_max,
    unique_id = FIXTURE_UUID,
    keyframes = decoded.keyframes,   -- sorted ascending by x: (0,y_max)->(x_max,0)
}
local encoded = enc.encode_media_timemap(spec)

-- ── Byte-exact golden ────────────────────────────────────────────────────
if encoded ~= REV_HEX then
    local n = math.min(#encoded, #REV_HEX)
    local first = nil
    for i = 1, n, 2 do
        if encoded:sub(i, i + 1) ~= REV_HEX:sub(i, i + 1) then first = i; break end
    end
    local pos = first or (n + 1)
    error(string.format(
        "encoder output does not byte-match Resolve's blob.\n"
        .. "  lengths: encoded=%d ref=%d (hex chars)\n"
        .. "  first diff at hex offset %d (byte %d):\n"
        .. "    encoded ...%s...\n"
        .. "    ref     ...%s...",
        #encoded, #REV_HEX, pos - 1, (pos - 1) / 2,
        encoded:sub(math.max(1, pos - 8), pos + 23),
        REV_HEX:sub(math.max(1, pos - 8), pos + 23)))
end
print("  ✓ encoder reproduces Resolve's reverse MTBA byte-for-byte")

-- ── Functional round-trip ────────────────────────────────────────────────
local rt = dec.decode_media_timemap(encoded)
assert(rt and rt.is_reverse == true, "re-encoded blob must decode as reverse")
assert(math.abs(rt.y_max - decoded.y_max) < 1e-9, "y_max round-trip")
assert(math.abs(rt.x_max - decoded.x_max) < 1e-9, "x_max round-trip")
print("  ✓ re-encoded blob decodes back to the same reverse curve")

print("✅ test_drt_reverse_mtba_golden.lua passed")
