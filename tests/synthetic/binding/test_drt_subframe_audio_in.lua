require("test_env")

-- =============================================================================
-- DRT writer — sub-frame <In> encoding (spec 026 T013a, FR-003).
--
-- After gap #1, an audio-only master clip's source_in / start_tc_frame are
-- FRAME-domain at the sequence fps but **fractional** (samples ÷ rate × fps).
-- The file-relative source-in (in_offset = source_in − start_tc_frame) is
-- therefore non-integer. Resolve encodes a non-integer <In> as
--   <whole_frames>|<hex little-endian IEEE-754 double of the fractional part>
-- NOT a rounded integer (that would silently shift the audio off the sample it
-- was cut on). Until T013a the writer asserted integer-only and loud-failed on
-- any fractional in_offset.
--
-- DOMAIN (byte-for-byte from a Resolve-authored fixture — retime-test.drt,
-- phase0-findings §C): a clip trimmed to a sub-frame point exports
--   <In>447|00f05d74d145e73f</In>
-- = whole frame 447 + the double 0x3fe745d1745df000 (BE) ≈ 0.72727… The hex is
-- the EXACT bytes Resolve wrote (extracted from the fixture, NOT recomputed by
-- this writer's own encoder — a self-computed expectation would pass under a
-- buggy encoder). The fractional double is derived FROM that hex via the
-- decoder so the in_offset fed to the writer is the precise value Resolve held.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drt_subframe_audio_in.lua
-- =============================================================================

local writer  = require("exporters.drt_writer")
local fixture = require("synthetic.helpers.drt_spike_fixture")
local dec     = require("importers.drp_binary")

local GOLD_WHOLE    = 447
local GOLD_FRAC_HEX = "00f05d74d145e73f"   -- verbatim Resolve bytes (retime-test.drt)
local GOLD_IN       = string.format("<In>%d|%s</In>", GOLD_WHOLE, GOLD_FRAC_HEX)

-- in_offset = the precise value Resolve encoded, reconstructed from the
-- fixture's own fractional double (decoder is the inverse of the writer's
-- encode_le_double — see drt_binary).
local frac      = dec.decode_hex_double(GOLD_FRAC_HEX)
local in_offset = GOLD_WHOLE + frac

-- Author a single forward audio clip whose file-relative source-in is the
-- fractional value, then pull the <In> element out of its Sm2TiAudioClip.
local function author_in_element(src_in)
    local p      = fixture.build_a005_payload()
    local atrack = p.sequence.tracks[2]
    local clip   = atrack.clips[1]
    clip.source_in  = src_in
    clip.source_out = src_in + 108         -- forward (source_out > source_in)
    p.sequence.tracks = { atrack }

    local out = fixture.out_path("test_drt_subframe_audio_in")
    os.remove(out)
    writer.author_a005_compatible(out, p)
    local xml = fixture.unzip_member(out, "SeqContainer/*.xml")
    os.remove(out)

    local open = string.format('<Sm2TiAudioClip DbId="%s">', clip.id)
    local lo   = assert(xml:find(open, 1, true), "no Sm2TiAudioClip in XML")
    local hi   = assert(xml:find("</Sm2TiAudioClip>", lo, true), "clip not closed")
    local subtree = xml:sub(lo, hi)
    return assert(subtree:match("(<In>[^<]*</In>)"), "no <In> in Sm2TiAudioClip")
end

local got = author_in_element(in_offset)
assert(got == GOLD_IN, string.format(
    "sub-frame <In> mismatch:\n  got:  %s\n  want: %s", got, GOLD_IN))

-- A whole-frame in_offset must still emit the bare-integer form (no spurious
-- pipe / zero-fraction double).
local whole_only = author_in_element(312)
assert(whole_only == "<In>312</In>", string.format(
    "whole-frame <In> regressed: got %s, want <In>312</In>", whole_only))

-- Large-offset sample exactness. Intuition says splitting a large combined
-- double (whole + frac) loses the fraction — it does NOT: for whole ≤ X <
-- whole+1 the subtraction X-whole is exact (Sterbenz), and whole+frac
-- reconstructs X. A ~1-hour-in audio source-in (frame-domain float, off the
-- frame grid) must therefore still reconstruct to the EXACT sample.
local FPS, RATE = 24, 48000
local samples_in = 172800001                 -- ~1 h at 48 kHz, off the frame grid
local big = author_in_element(samples_in * FPS / RATE)
local w, h = big:match("^<In>(%d+)|(%x+)</In>$")
assert(w and h, "large offset must emit the pipe form, got " .. big)
local recon_samples = math.floor(
    (tonumber(w) + dec.decode_hex_double(h)) * RATE / FPS + 0.5)
assert(recon_samples == samples_in, string.format(
    "large-offset sample drift: in=%d reconstructed=%d", samples_in, recon_samples))

print("✅ test_drt_subframe_audio_in.lua passed")
