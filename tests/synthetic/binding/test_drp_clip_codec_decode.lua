require("test_env")

-- =============================================================================
-- DRP import — Clip-blob codec decode (spec 026 gap #4, T018/T007, FR-010).
--
-- The BtVideoInfo/BtAudioInfo <Clip> protobuf carries the media codec in field
-- 5. The importer decoded path but NOT codec, so media.codec stayed empty for
-- every gold media — and the DRT writer then hard-coded "avc1"/"AAC".
-- decode_bt_clip_codec reads f5 so the codec round-trips (import → media.codec
-- → export).
--
-- WHY A BINDING (--test) TEST, not pure-lua: the VIDEO Clip blob is a
-- zstd-COMPRESSED FieldsBlob; reading its codec needs decode_fields_blob, which
-- calls the C++ zstd binding (absent in bare luajit). The audio blob is an
-- uncompressed zstd block but decode_fields_blob inflates it the same way.
--
-- DOMAIN: three Resolve-authored Clip blobs with DIFFERENT real codecs (so a
-- single constant can't pass): the A005 video stream = "avc1" (compressed
-- blob), its embedded audio = "AAC", and the standalone-audio reference =
-- "Linear PCM". Golden codecs are the literal bytes Resolve wrote, extracted
-- from the committed reference templates.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_clip_codec_decode.lua
-- =============================================================================

local drp_binary = require("importers.drp_binary")
local path_utils = require("core.path_utils")

local function read(p)
    local h = assert(io.open(p, "r"), "cannot open " .. p)
    local s = h:read("*a"); h:close(); return s
end
local function clip_blobs(rel)
    local x = read(path_utils.resolve_repo_root()
        .. "/src/lua/exporters/drt_canonical/" .. rel)
    local out = {}
    for hex in x:gmatch("<Clip>([0-9a-f]+)</Clip>") do out[#out + 1] = hex end
    return out
end

-- Standalone-audio reference: its single Clip blob is Linear PCM.
local audio = clip_blobs("full_reference_mp_audio_clip.xml")
assert(#audio == 1, "expected one Clip in the audio reference")
assert(drp_binary.decode_bt_clip_codec(audio[1]) == "Linear PCM", string.format(
    "audio Clip codec: got %q, want \"Linear PCM\"",
    tostring(drp_binary.decode_bt_clip_codec(audio[1]))))

-- A005 video item: the BtVideoInfo Clip (compressed) is avc1; its embedded
-- BtAudioInfo Clip is AAC. Two distinct codecs from one item.
local video = clip_blobs("full_reference_mp_video_clip_a005.xml")
local codecs = {}
for _, hex in ipairs(video) do
    local c = drp_binary.decode_bt_clip_codec(hex)
    if c then codecs[c] = true end
end
assert(codecs["avc1"], "A005 video stream codec avc1 not decoded (compressed blob)")
assert(codecs["AAC"], "A005 embedded-audio codec AAC not decoded")

print("✅ test_drp_clip_codec_decode.lua passed")
