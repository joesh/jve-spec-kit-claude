require("test_env")

-- =============================================================================
-- DRT writer — VirtualAudioTrackBA + MediaTrackIdx are payload-driven (gap #3,
-- FR-007/008/009). Until T015 the writer hardcoded the mono-ch1-embedded blob
-- (VIRTUAL_AUDIO_TRACK_BA_MONO_A1) and <MediaTrackIdx>0</MediaTrackIdx> for
-- EVERY audio clip. A clip reading a different file channel, or a stereo
-- (composite) clip, therefore exported with the wrong routing bytes and
-- Resolve mis-routed / mis-grouped the audio.
--
-- DOMAIN (research D11, byte-for-byte from resolve_authored_full.drp +
-- anamnesis-gold-timeline.drp SeqContainer XML):
--   VirtualAudioTrackBA = a Fusion Fields blob carrying two fields:
--     • ChannelsBA  — block size = 8 + 4·nchannels; one 4-byte descriptor per
--                     channel: [routing-type][00][40][1-based-file-channel],
--                     routing-type 0x00 = embedded/standalone, 0x20 = synced.
--     • AudioType   — trailing 1-byte type code: 0x01 = mono, 0x00 = stereo.
--   MediaTrackIdx = the routing descriptor's media_track_idx (0 for an
--                   embedded ch1 / composite stereo, source_channel for a
--                   pinned single channel, 2 for the synced virtual-track slot).
--
-- The golden hex below is the EXACT bytes Resolve writes (extracted from the
-- fixtures, not recomputed by the writer's own encoder — a self-computed
-- expectation would pass under a buggy encoder). Each form is keyed to a
-- routing descriptor the producer (payload_builder.build_audio_routing) emits.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drt_writer_vatba.lua
-- =============================================================================

local writer  = require("exporters.drt_writer")
local fixture = require("synthetic.helpers.drt_spike_fixture")

-- Fixture-derived golden VirtualAudioTrackBA forms (verbatim wire bytes).
local GOLD_MONO_CH2 =
    "000000010000000200000014004300680061006e006e0065006c0073004200" ..
    "410000000c000000000c00000002000000010000400200000012004100750064" ..
    "0069006f00540079007000650000000200000000" .. "01"
local GOLD_STEREO =
    "000000010000000200000014004300680061006e006e0065006c0073004200" ..
    "410000000c000000001000000002000000020000400100004002000000120041" ..
    "007500640069006f00540079007000650000000200000000" .. "00"
local GOLD_SYNC_CH1 =
    "000000010000000200000014004300680061006e006e0065006c0073004200" ..
    "410000000c000000000c00000002000000012000400100000012004100750064" ..
    "0069006f00540079007000650000000200000000" .. "01"

local function check(cond, msg)
    assert(cond, "VATBA shape FAILED: " .. tostring(msg))
end

-- Author a single-audio-clip payload with the given routing, return the
-- Sm2TiAudioClip subtree of the resulting SeqContainer XML.
local function author_audio_clip_subtree(routing, tag)
    local p = fixture.build_a005_payload()
    -- Drop the video track; keep only the embedded-audio clip (it points at
    -- the A005 master, whose media-pool item already exists — no gap #2 item
    -- needed). Attach the routing under test.
    local audio_track = p.sequence.tracks[2]
    audio_track.clips[1].routing = routing
    p.sequence.tracks = { audio_track }

    local out = fixture.out_path("test_drt_writer_vatba_" .. tag)
    os.remove(out)
    writer.author_a005_compatible(out, p)
    local xml = fixture.unzip_member(out, "SeqContainer/*.xml")
    os.remove(out)

    local clip_id = audio_track.clips[1].id
    local open = string.format('<Sm2TiAudioClip DbId="%s">', clip_id)
    local lo, hi = xml:find(open, 1, true)
    check(lo, tag .. ": no " .. open .. " in SeqContainer/*.xml")
    local close = xml:find("</Sm2TiAudioClip>", hi, true)
    check(close, tag .. ": Sm2TiAudioClip not closed")
    return xml:sub(lo, close + #"</Sm2TiAudioClip>" - 1)
end

local function expect_inside(subtree, needle, hint)
    check(fixture.plain_count(subtree, needle) == 1,
        string.format("expected %s. Hint: %s", needle, hint))
end

-- ── Case 1: mono, pinned to file channel 2 (source_channel = 1) ────────────
-- Today's hardcode emits ch1 / MediaTrackIdx 0 → this is the RED case.
local mono = author_audio_clip_subtree(
    { kind = "mono", media_track_idx = 1, source_channel = 1 }, "mono_ch2")
expect_inside(mono,
    "<VirtualAudioTrackBA>" .. GOLD_MONO_CH2 .. "</VirtualAudioTrackBA>",
    "mono ch2: channel descriptor byte must be 0x02 (1-based file ch 2)")
expect_inside(mono, "<MediaTrackIdx>1</MediaTrackIdx>",
    "mono ch2: MediaTrackIdx = source_channel = 1 (not the hardcoded 0)")

-- ── Case 2: stereo composite (reads channels 1+2) ──────────────────────────
local stereo = author_audio_clip_subtree(
    { kind = "stereo", media_track_idx = 0, source_channel = nil }, "stereo")
expect_inside(stereo,
    "<VirtualAudioTrackBA>" .. GOLD_STEREO .. "</VirtualAudioTrackBA>",
    "stereo: 2-channel block (size 0x10), descriptors ch1+ch2, AudioType 0x00")
expect_inside(stereo, "<MediaTrackIdx>0</MediaTrackIdx>",
    "stereo composite: MediaTrackIdx = 0")

-- ── Case 3: synced → loud fail (gap #5 owns the virtual-track slot + the
--    channel selection; the writer must NOT silently emit a guessed form). ──
local ok = pcall(author_audio_clip_subtree,
    { kind = "synced", media_track_idx = 2, source_channel = nil }, "synced")
check(not ok,
    "synced routing must loud-fail at the writer (gap #5, FR-014) — not "
    .. "silently emit a mono/stereo form")

-- The GOLD_SYNC_CH1 form documents the eventual synced bytes (routing-type
-- 0x20) for when gap #5 lands; reference it so the constant isn't dead.
check(#GOLD_SYNC_CH1 > 0, "synced golden form documented for gap #5")

print("✅ test_drt_writer_vatba.lua passed")
