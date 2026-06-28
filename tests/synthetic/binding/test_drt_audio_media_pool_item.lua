require("test_env")

-- =============================================================================
-- DRT writer — standalone-audio media-pool item (spec 026 gap #2, T017,
-- FR-004/005/006/019). A standalone .wav used by a sequence needs its own
-- `Sm2MpAudioClip` media-pool item, or Resolve drops the clip. Until T017 the
-- writer loud-failed ("not yet implemented") for any audio media_ref.
--
-- DOMAIN (byte-for-byte from Resolve-authored fixtures):
--   • The Sm2MpAudioClip shape (child order, fixed Fusion blobs) comes from
--     resolve_authored_full.drp's test_click_48k_stereo.wav, committed as
--     drt_canonical/full_reference_mp_audio_clip.xml.
--   • File-specific fields are substituted from the media: Name, the BtAudioInfo
--     Clip blob (path/date/mtime), and the TracksBA (SampleRate/NumChannels/
--     Duration). Authoring with the fixture's own values must reproduce the
--     fixture's Clip + TracksBA bytes exactly.
--   • VirtualAudioTracksBA is a per-channel-count CONSTANT (not media-derived):
--     stereo = the test_click form (reference XML); mono = the form Resolve
--     wrote for all 12 standalone WAVs in anamnesis-gold-timeline.drp
--     (byte-identical across all 12). An unsupported channel count loud-fails.
--
-- Golden bytes are extracted from the fixtures, NOT recomputed by the writer's
-- own encoder (a self-computed expectation would pass under a buggy encoder).
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drt_audio_media_pool_item.lua
-- =============================================================================

local writer     = require("exporters.drt_writer")
local fixture    = require("synthetic.helpers.drt_spike_fixture")
local path_utils = require("core.path_utils")

local function check(cond, msg) assert(cond, "audio MP item FAILED: " .. tostring(msg)) end

-- ── Golden bytes from the committed reference XML (test_click stereo) ───────
local REF_PATH = path_utils.resolve_repo_root()
    .. "/src/lua/exporters/drt_canonical/full_reference_mp_audio_clip.xml"
local rh = assert(io.open(REF_PATH, "r"), "cannot open reference XML " .. REF_PATH)
local REF = rh:read("*a"); rh:close()
local function ref_elem(tag)
    return assert(REF:match("<" .. tag .. ">([0-9a-f]+)</" .. tag .. ">"),
        "reference XML missing hex <" .. tag .. ">")
end
local GOLD_VATBA_STEREO = ref_elem("VirtualAudioTracksBA")
local GOLD_TRACKS_BA    = ref_elem("TracksBA")
local GOLD_CLIP         = ref_elem("Clip")

-- mono VirtualAudioTracksBA — Resolve's standalone-mono form, byte-identical
-- across all 12 mono WAVs in anamnesis-gold-timeline.drp (verbatim fixture
-- bytes; see reference_026_mp_item_vatba_per_channel_constant).
local GOLD_VATBA_MONO =
    "00000001000000010000000200300000000c0000000074000000010000000200" ..
    "000014004300680061006e006e0065006c0073004200410000000c000000002c" ..
    "0000000200000009000040010000800140000000400000004000000040000000" ..
    "400000004000000040000000000000120041007500640069006f005400790070" ..
    "0065000000020000000109"

-- Author and return the single Sm2MpAudioClip <Element> subtree.
local function author_audio_item(audio_overrides, tag)
    local p   = fixture.build_standalone_audio_payload(audio_overrides)
    local out = fixture.out_path("test_drt_audio_mp_item_" .. tag)
    os.remove(out)
    writer.author_a005_compatible(out, p)
    local xml = fixture.unzip_member(out, "MediaPool/*/MpFolder.xml")
    os.remove(out)
    local lo = assert(xml:find("<Sm2MpAudioClip", 1, true),
        tag .. ": no Sm2MpAudioClip authored")
    check(not xml:find("<Sm2MpAudioClip", lo + 1, true),
        tag .. ": more than one Sm2MpAudioClip (expected exactly one)")
    local hi = assert(xml:find("</Sm2MpAudioClip>", lo, true), tag .. ": not closed")
    return xml:sub(lo, hi + #"</Sm2MpAudioClip>" - 1)
end

-- ── Stereo case (reproduces the fixture's own values → byte-equal blobs) ────
local stereo = author_audio_item(nil, "stereo")

-- Child order matches the reference Sm2MpAudioClip schema (§K2 / D4a).
local EXPECTED_ORDER = {
    "FieldsBlob", "Name", "MpFolder", "UniqueMediaPoolItemId",
    "MarkIn", "MarkInVideo", "MarkInAudio", "MarkOut", "MarkOutVideo", "MarkOutAudio",
    "CurPlayheadPosition", "PinsBA", "VirtualAudioTracksBA", "EmbeddedAudioVec",
}
local last = 0
for _, tag in ipairs(EXPECTED_ORDER) do
    local at = stereo:find("<" .. tag .. "[ />]")
    check(at and at > last, "child order: <" .. tag .. "> missing or out of order")
    last = at
end

check(stereo:find("<Name>test_click_48k_stereo.wav</Name>", 1, true),
    "Name = basename of the media file_path")
check(fixture.plain_count(stereo,
    "<VirtualAudioTracksBA>" .. GOLD_VATBA_STEREO .. "</VirtualAudioTracksBA>") == 1,
    "stereo VirtualAudioTracksBA = the 2-channel fixture constant")
check(fixture.plain_count(stereo, "<TracksBA>" .. GOLD_TRACKS_BA .. "</TracksBA>") == 1,
    "TracksBA byte-equal to fixture (48000 / 2ch / 144000 samples)")
check(fixture.plain_count(stereo, "<Clip>" .. GOLD_CLIP .. "</Clip>") == 1,
    "BtAudioInfo Clip blob byte-equal to fixture (path/date/mtime)")

-- ── Mono case (channel-count-selected constant; NumChannels substituted) ───
local mono = author_audio_item(
    { num_channels = 1, duration_samples = 96000 }, "mono")
check(fixture.plain_count(mono,
    "<VirtualAudioTracksBA>" .. GOLD_VATBA_MONO .. "</VirtualAudioTracksBA>") == 1,
    "mono VirtualAudioTracksBA = the 1-channel anamnesis-gold constant")
-- NumChannels field value 1 (TLV int5: 4-byte BE aux 0 + 1-byte val 01).
check(mono:find("004e0075006d004300680061006e006e0065006c0073000000020000000001", 1, true),
    "mono TracksBA NumChannels substituted to 1")

-- ── FR-019: unsupported inputs loud-fail (never silently mis-author) ───────
check(not pcall(author_audio_item, { num_channels = 6 }, "sixch"),
    "unsupported channel count must loud-fail (no fixture VATBA)")
check(not pcall(author_audio_item,
    { file_path = "/tmp/foo.aif" }, "aif"),
    "non-.wav audio must loud-fail (FR-019), not author a guessed item")

print("✅ test_drt_audio_media_pool_item.lua passed")
