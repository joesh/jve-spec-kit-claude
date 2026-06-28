require("test_env")

-- =============================================================================
-- DRT writer — the video media-pool item (Sm2MpVideoClip) is SYNTHESIZED from
-- the payload media, not borrowed from the A005 template (spec 026 gap #4,
-- T020/T021, FR-010/011).
--
-- DOMAIN: the writer used to emit A005's baked descriptors verbatim — so EVERY
-- exported video carried A005's 640×360 Geometry, A005's embedded-audio shape,
-- and a hard-coded "avc1" codec, regardless of the real file. Resolve then
-- showed the wrong resolution / offline media. The descriptors must instead
-- carry THIS media's intrinsic resolution, embedded-audio characteristics, and
-- codec.
--
-- Golden values = what Resolve authored for A035_11200051_C049.mov in the
-- anamnesis-gold timeline: 2048×1152, ProRes "ap4h", embedded audio 2ch @
-- 48000 Hz, 3734400 samples. Authoring an A035-shaped payload and decoding the
-- emitted descriptors back must reproduce them.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drt_writer_video_item_synthesized.lua
-- =============================================================================

local writer     = require("exporters.drt_writer")
local fixture    = require("synthetic.helpers.drt_spike_fixture")
local drp_binary = require("importers.drp_binary")

-- A035_11200051_C049.mov — Resolve-authored intrinsic descriptors.
local GOLDEN_WIDTH    = 2048
local GOLDEN_HEIGHT   = 1152
local GOLDEN_CODEC    = "ap4h"
local GOLDEN_SR       = 48000
local GOLDEN_CH       = 2
local GOLDEN_SAMPLES  = 3734400

local payload = fixture.build_a005_payload()
local media = payload.media_refs[1]
-- Re-shape the single video media into A035: a non-A005 resolution, a ProRes
-- codec, and a distinct embedded-audio sample count. A writer that borrows the
-- A005 descriptors would emit 640×360 / "avc1" / 218112 and fail below.
media.file_path     = "/Volumes/Cam/A035_11200051_C049.mov"
media.width         = GOLDEN_WIDTH
media.height        = GOLDEN_HEIGHT
media.codec         = GOLDEN_CODEC
media.embedded_audio = {
    sample_rate      = GOLDEN_SR,
    num_channels     = GOLDEN_CH,
    duration_samples = GOLDEN_SAMPLES,
}

local OUT = fixture.out_path("test_drt_writer_video_item_synthesized")
os.remove(OUT)
writer.author_a005_compatible(OUT, payload)

local mp_folder_xml = fixture.unzip_member(OUT, "MediaPool/Master/MpFolder.xml")
os.remove(OUT)

-- (1) Geometry resolution = the media's intrinsic dimensions.
local geom = assert(mp_folder_xml:match("<Geometry>([0-9a-f]+)</Geometry>"),
    "no <Geometry> blob in the emitted Sm2MpVideoClip")
local w, h = drp_binary.decode_bt_video_resolution(geom)
assert(w == GOLDEN_WIDTH and h == GOLDEN_HEIGHT, string.format(
    "Geometry resolution not synthesized from media: got %sx%s, want %dx%d "
    .. "(writer borrowed the A005 template's 640x360)",
    tostring(w), tostring(h), GOLDEN_WIDTH, GOLDEN_HEIGHT))

-- (2) Embedded-audio TracksBA = the media's embedded-audio shape.
local tb = assert(mp_folder_xml:match("<TracksBA>([0-9a-f]+)</TracksBA>"),
    "no embedded <TracksBA> blob in the emitted Sm2MpVideoClip")
local a = drp_binary.decode_bt_audio_duration(tb)
assert(a and a.sample_rate == GOLDEN_SR and a.num_channels == GOLDEN_CH
    and a.duration_samples == GOLDEN_SAMPLES, string.format(
    "embedded TracksBA not synthesized: got sr=%s ch=%s samples=%s, "
    .. "want sr=%d ch=%d samples=%d (writer borrowed A005's embedded audio)",
    a and tostring(a.sample_rate), a and tostring(a.num_channels),
    a and tostring(a.duration_samples), GOLDEN_SR, GOLDEN_CH, GOLDEN_SAMPLES))

-- (3) Video Clip codec = the media's codec (first <Clip> = BtVideoInfo).
local video_clip = assert(mp_folder_xml:match("<Clip>([0-9a-f]+)</Clip>"),
    "no <Clip> blob in the emitted Sm2MpVideoClip")
local codec = drp_binary.decode_bt_clip_codec(video_clip)
assert(codec == GOLDEN_CODEC, string.format(
    "video Clip codec not driven by media.codec: got %q, want %q "
    .. "(writer hard-coded 'avc1')", tostring(codec), GOLDEN_CODEC))

print("✅ test_drt_writer_video_item_synthesized.lua passed")
