-- Regression + stage-2 gate: Sm2Mp*.FieldsBlob decoding.
--
-- Every Sm2Mp* pool item carries a FieldsBlob whose on-the-wire shape is:
--   [BE32 version][BE32 declared_size][0x81 marker][zstd frame]
-- decompressing to a protobuf-shaped payload. For synced-clip support we
-- need just two things out of the payload:
--   1. The ordered list of MediaRef UUIDs (each one is a BtAudioInfo DbId).
--   2. Resilience to malformed wrappers / non-zstd bodies — surface with a
--      readable error rather than crashing the importer.
--
-- This test runs in pure Lua (no --test harness) but needs the
-- qt_zstd_decompress binding to be live. The harness stubs it in via the
-- zstandard CLI so we get real round-trips without pulling in the editor.

require("test_env")

print("=== test_drp_fields_blob_decode.lua ===")

-- Stub qt_zstd_decompress using the zstd CLI (present on every dev Mac).
-- The real binding (C++) has the same contract: (frame) → (string | nil, err).
if type(qt_zstd_decompress) ~= "function" then
    _G.qt_zstd_decompress = function(frame)
        if type(frame) ~= "string" or #frame == 0 then
            return nil, "zstd: empty input"
        end
        local tmp_in = os.tmpname()
        local tmp_out = os.tmpname()
        local fh = assert(io.open(tmp_in, "wb"))
        fh:write(frame); fh:close()
        local ok = os.execute(string.format(
            "zstd -d -q -f -o %q %q 2>/dev/null", tmp_out, tmp_in))
        os.remove(tmp_in)
        if ok ~= 0 and ok ~= true then
            os.remove(tmp_out)
            return nil, "zstd: decompress failed"
        end
        local ofh = assert(io.open(tmp_out, "rb"))
        local out = ofh:read("*a"); ofh:close()
        os.remove(tmp_out)
        return out
    end
end

local drp_binary = require("importers.drp_binary")

-- ─────────────────────────────────────────────────────────────────────
-- decode_fields_blob: strips the 9-byte wrapper and decompresses. Real
-- synced Sm2MpVideoClip FieldsBlob from the example DRP.
-- ─────────────────────────────────────────────────────────────────────
local SYNCED_HEX =
    "00000002000001ec81" ..
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
local UNSYNCED_HEX =
    "0000000200000147" .. "81" ..
    "28b52ffd604701e5090046533e39606dd21cc014b44d44004ba4142e6480190660a1e1876d7" ..
    "bab6f934b2c409218a4daa3d9461010fd4bc62eb6ce80ce0e8d388e0b234bc8de293b002900" ..
    "29001306f844c973016fa1e7936780d230a7c94844320c161940380828aa591c9766a1a8eaa" ..
    "2715c5acb205019c0618487101280e84044e91051404401477739af106aba5890d6ca33198f" ..
    "4c090911253e6ca82015d999753b473278ddc4ba1b2b4eee862419d31613637b31c1b6dac0a" ..
    "32b41d2900a1d2af064d4a0d042f6fad15af18dd6082d5e7875b39b0f521cefbdf7de7b134b" ..
    "15e863674877c1ce4d8dd2c36923b10e2834ab0a62c4ac76ac5aa6d44b2ce6b4594e3bae011" ..
    "900d22b46e7456c01e9c031903d6998828bb5cab266f3d0c0a7e4ef3cbdd5181e4f5f263210" ..
    "9b8edbad77780d37802013fc3c83b759111c8673d6a6a3baebf6"

local bytes_syn, err = drp_binary.decode_fields_blob(SYNCED_HEX)
assert(bytes_syn, "decode_fields_blob failed: " .. tostring(err))
assert(#bytes_syn == 2670, string.format(
    "synced FieldsBlob: expected 2670-byte decompressed payload, got %d", #bytes_syn))
assert(bytes_syn:find("A008_05211408_C011.mov synced", 1, true),
    "decompressed synced payload missing clip name")
print(string.format("  ✓ synced FieldsBlob decoded (%d bytes)", #bytes_syn))

local bytes_un = assert(drp_binary.decode_fields_blob(UNSYNCED_HEX))
assert(#bytes_un == 583, string.format(
    "unsynced FieldsBlob: expected 583 bytes, got %d", #bytes_un))
print(string.format("  ✓ unsynced FieldsBlob decoded (%d bytes)", #bytes_un))

-- ─────────────────────────────────────────────────────────────────────
-- extract_media_refs: returns the ordered list of MediaRef UUIDs (each
-- one is a BtAudioInfo DbId) from a decompressed FieldsBlob.
--
-- Domain invariants derived from the fixture pair:
--   - Synced video's FieldsBlob references TWO distinct BtAudioInfo UUIDs
--     (the external WAV's audio info + the video's embedded audio info).
--   - External-audio UUID appears more times than the embedded one
--     (synced clip's primary audio is the external WAV).
--   - Unsynced video references exactly ONE BtAudioInfo (its own embedded).
--
-- Specific UUIDs are ground truth from the example DRP:
--   external WAV audio info:  580b74c0-67a8-4b4e-8005-c02df71eccc2
--   synced video's embedded:  5c14f5ac-cbc5-454c-a348-fce0ae1f9691
--   unsynced video's own:     20350790-a79b-4500-9d81-3542b29762c1
-- ─────────────────────────────────────────────────────────────────────
local refs_syn = drp_binary.extract_media_refs(bytes_syn)
assert(type(refs_syn) == "table", "extract_media_refs should return a table")
local distinct_syn = {}
for _, u in ipairs(refs_syn) do distinct_syn[u] = (distinct_syn[u] or 0) + 1 end

local WAV_AUDIO_INFO = "580b74c0-67a8-4b4e-8005-c02df71eccc2"
local SYNC_VID_EMBED = "5c14f5ac-cbc5-454c-a348-fce0ae1f9691"
local UNSYNC_VID_EMBED = "20350790-a79b-4500-9d81-3542b29762c1"

assert(distinct_syn[WAV_AUDIO_INFO], string.format(
    "synced payload must reference external WAV's BtAudioInfo (%s), refs=%s",
    WAV_AUDIO_INFO, table.concat(refs_syn, ",")))
assert(distinct_syn[SYNC_VID_EMBED], string.format(
    "synced payload must also reference video's own embedded audio (%s)",
    SYNC_VID_EMBED))
assert(distinct_syn[WAV_AUDIO_INFO] > distinct_syn[SYNC_VID_EMBED],
    "external audio should be referenced more often than embedded")
print(string.format("  ✓ synced refs: %d×WAV, %d×embedded",
    distinct_syn[WAV_AUDIO_INFO], distinct_syn[SYNC_VID_EMBED]))

local refs_un = drp_binary.extract_media_refs(bytes_un)
local distinct_un = {}
for _, u in ipairs(refs_un) do distinct_un[u] = (distinct_un[u] or 0) + 1 end
-- Exactly one distinct UUID — the video's own embedded audio info.
assert(next(distinct_un, next(distinct_un)) == nil, string.format(
    "unsynced payload must reference exactly one BtAudioInfo, got %d distinct",
    (function() local n = 0; for _ in pairs(distinct_un) do n = n + 1 end; return n end)()))
assert(distinct_un[UNSYNC_VID_EMBED], string.format(
    "unsynced payload's sole reference should be its own embedded audio (%s)",
    UNSYNC_VID_EMBED))
print(string.format("  ✓ unsynced refs: %d×embedded", distinct_un[UNSYNC_VID_EMBED]))

-- ─────────────────────────────────────────────────────────────────────
-- Error surfaces: malformed wrapper → (nil, err); too-short → (nil, err).
-- Importer uses these error strings to attach clip context in logs.
-- ─────────────────────────────────────────────────────────────────────
local _, err1 = drp_binary.decode_fields_blob("")
assert(err1 and err1:match("FieldsBlob"), "empty hex must error: got " .. tostring(err1))

local _, err2 = drp_binary.decode_fields_blob("00000002000000058182deadbeef")
-- Valid wrapper header, but the payload after 0x81 is not zstd. Must fail.
assert(err2, "non-zstd body must error")
print("  ✓ malformed FieldsBlob surfaces as error")

print("\n✅ test_drp_fields_blob_decode.lua passed")
