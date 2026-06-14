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
-- Media-managed clips: audio refs are ONLY the `MediaRef` field values, not
-- every UUID in the blob.
--
-- A media-managed Resolve project's video FieldsBlob additionally carries
-- per-clip/version `UniqueId` UUIDs (under VideoMetadata), codec refs, etc.
-- These are NOT audio. extract_media_refs must return only the BtAudioInfo
-- DbIds referenced via `MediaRef` fields — a UUID-shape scrape used to sweep
-- the UniqueId noise in too, making the importer report thousands of
-- non-existent "failed audio links".
--
-- This is a real Sm2MpVideoClip FieldsBlob from a media-managed export
-- (A035_11200051_C049.mov). Ground truth from the archive's BtAudioInfo set:
--   audio refs (MediaRef → BtAudioInfo, per channel):
--     a288f8cf-b6d5-433a-a805-5a1175a85942  (×4 channels)
--     5ed0f471-64bf-4eb6-b196-9fb2d0e5dd7f  (×2 channels)
--   non-audio noise that must NOT appear (a VideoMetadata UniqueId):
--     0436b52f-ba85-4bb3-94ea-ab8c8451d19c
-- ─────────────────────────────────────────────────────────────────────
local MEDIA_MANAGED_VIDEO_HEX =
    "000000020000059a8128b52ffd6004127d2c00ca48540d47e094386b90d0185f4810c611" ..
    "e180b07c33abea286e4e25f928783a4b210d1bb3033f768458d97db35c866a9c9697bd47" ..
    "fd8db0976db4b4dcf8f31828981aadd676a80ad0fedf29b100b800c600e5e378eaef6ff3" ..
    "d19bdcbcdb3c3c5cbc7b3c1df579b73a3ab93a3939b87904f5fb4b1204267ffef63b6d75" ..
    "75d8f79a6f621e1a7b5c8fd50e64ae916d4e33ebd2ff9ab5cba6679bdf09a3fc87febbcd" ..
    "e62da3dfd3d9598ffe15991bffaf04a9b0f22f9a76bbec7bbb6d96cdd7d3efaf4b7b7ed9" ..
    "eb175e9f0dfb0405f79ffce29d1ff473bf0889828fd7e16630617252ba0e2d4b13cb49e9" ..
    "3a5cd945633929a59100151f56ac10010825080d60111a60231469783a09a0c15a5e7571" ..
    "74f40e257e9fe464f978b93a1efe997d3fb7b976cbfde59acd6bb7a3af36b53bd8c0790b" ..
    "4dff1e1727cfbb187e7627f8f839ca4b777dafade175d9311e1f9bb79ba79bb7ecbacc04" ..
    "fe121e20d80f6ed9f5ccb0596eed5ac68382639404f48f3a367ba9d3d3c72ff8b97a59fe" ..
    "7ddeddc57371d4dddfa9c5d5bd51c4d739c0c568611886e14a8b052a44708cb0f0cd38c3" ..
    "5c22c4eb987861fb38b00342c18577686ebff9deba7dddc122dbe92e70f1a33184ad4ee0" ..
    "67c2315b27734def0bc7c6ce5c4eb4bb6e605fa7cb6238d166971673520999e4189412c3" ..
    "74e42443c5038c1937afd7cc625797ed22a1dce1f07aecf6f9924fd8d7db6bd7cc4efbfe" ..
    "f28da2a7e2f78b9277e6e2d77da8c1d1cf101b088b5abb2e6cbe365b13289d8fe5e2e0a9" ..
    "c3cfc1ef1d3879b72adebdbf3bd4dfe8a83f8f0edbecb35de64e801c081377c360ebdc74" ..
    "44b692db08e7d92dfbfa32ca93cafb8222006df477f683db67316fd5e2e12ad5dede2454" ..
    "f4a9bb4bb31c5c4457f7bc032f968b69665ed93a21b4e747ce8710a4daabd2cd0859bbb5" ..
    "4d44fa6f357e8f85113888a82c68b1328011fa2d5377e55dfd5b44818beaa34909ce0547" ..
    "3bc328cca252bda87474717214d5bbcd6f340579fe13d62ccb3c5360933f36cc2db30c33" ..
    "85599e39b68459af7e19e69961bb6e1df36a951f2506069039ee76e348a4dcad63eb14f9" ..
    "e1610789143768ca94982a55b40ccbf2eb5490343b10bc62774bef762499226f0aa20954" ..
    "208bde981f0520e88126f153a144d5f8993ed074a1b632c96ab112810dac0d8352f45833" ..
    "dfe8791ef87d3363e8ad480180fda80141244949052345490a2ae9500221226355e60112" ..
    "e8865c479432849090444482092490918282324ad206566021e91d08d7019a87ed2c2328" ..
    "02b28ac44828508a74f01e4ec4758c7ff37b541e440b050a968a0729455c49100d337231" ..
    "1e9c85632a9ecd5e0c068164e7d3fe17ce07624286c70ee0713877121548b2e08c85c52b" ..
    "c812b4e1119138ca4f0e1380ab98d736a9880022f7905a04dbc2970471cf5f6a27d41718" ..
    "0103f3bd1c1a40259203023c06f761066429b2b4e2c77209c3c058bbcaf268d6424660c4" ..
    "f66aafeeb1263940523d9d15acb3bf4716b6decf011deaf91c6dce1d527970d708e35c56" ..
    "00fc58a3a8a92c83c31d2c7c86bd067753b64c9ee24f0054cb844fb7ca71c95a9c87fa8a" ..
    "41e0edf163885a3cf85840f7efcd78df08a73a8824c2b8e9e119efbe45e5352018658859" ..
    "a51411e62065ebc23384b85d20a94005ae8539f06fe1a648cab960f61df63f92c50da763" ..
    "fb531fe35dd364ae015ad86b4c243b3634158f10a735a467a623748d044eb08d15322ab2" ..
    "f50695c91791e20330c23ae8a05bb0d1fc682ce00450e7bf353a9f4ec1273606cfa76f56" ..
    "bd5e4050063321b61648f0fa92d7aa893a01232660acfed001a81447352efe71c4be2a11" ..
    "9b8a8c1b56c763b6f84b242ca52a319e0057130626480a215ccc4f272a76501871da58c8" ..
    "61d58e5055e1444da00d444ba05d5b3d23b1b3e6b27af15e813164a02faabdedb5998ad4" ..
    "d353483e96899bc7a2d630ea407760239d1452af280046ec553ae6ff973ca7402093a14d" ..
    "a506"

local mm_bytes = assert(drp_binary.decode_fields_blob(MEDIA_MANAGED_VIDEO_HEX),
    "media-managed FieldsBlob failed to decode")
local mm_refs = drp_binary.extract_media_refs(mm_bytes)
local mm_counts = {}
for _, u in ipairs(mm_refs) do mm_counts[u] = (mm_counts[u] or 0) + 1 end

local MM_AUDIO_A = "a288f8cf-b6d5-433a-a805-5a1175a85942"
local MM_AUDIO_B = "5ed0f471-64bf-4eb6-b196-9fb2d0e5dd7f"
local MM_NOISE   = "0436b52f-ba85-4bb3-94ea-ab8c8451d19c"

assert(mm_counts[MM_AUDIO_A] == 4, string.format(
    "media-managed clip's primary audio ref must appear once per channel (4×), got %s",
    tostring(mm_counts[MM_AUDIO_A])))
assert(mm_counts[MM_AUDIO_B] == 2, string.format(
    "media-managed clip's second audio ref must appear once per channel (2×), got %s",
    tostring(mm_counts[MM_AUDIO_B])))
assert(not mm_counts[MM_NOISE], string.format(
    "non-audio VideoMetadata UniqueId (%s) must NOT be returned as an audio ref",
    MM_NOISE))
-- The blob contains exactly two distinct audio sources; everything else in it
-- is non-audio and must be excluded.
local mm_distinct = 0
for _ in pairs(mm_counts) do mm_distinct = mm_distinct + 1 end
assert(mm_distinct == 2, string.format(
    "media-managed clip must yield exactly 2 distinct audio refs (no UniqueId/"
    .. "codec noise), got %d", mm_distinct))
print(string.format("  ✓ media-managed refs: %d×A, %d×B, 0 noise (UniqueId excluded)",
    mm_counts[MM_AUDIO_A], mm_counts[MM_AUDIO_B]))

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
