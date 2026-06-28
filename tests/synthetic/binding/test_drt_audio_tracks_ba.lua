require("test_env")

-- =============================================================================
-- DRT writer — BtAudioInfo TracksBA substitution (gap #2, FR-004/005/006).
--
-- A standalone-audio media-pool item (Sm2MpAudioClip) carries a BtAudioInfo
-- TracksBA blob describing the file: SampleRate, NumChannels, Duration (in
-- samples). The writer borrows the blob's fixed Fusion-fields structure from a
-- Resolve-authored fixture and substitutes only those file-specific values.
--
-- DOMAIN (research D4a, byte-for-byte from resolve_authored_full.drp
-- test_click_48k_stereo.wav): TracksBA is a plaintext Fusion-fields blob; each
-- field's value follows its UTF-16BE name + (be16 0)(be16 type). Values encode
-- as aux*256 + val (NOT a plain BE int):
--   • SampleRate  type 0x0003 → 4-byte BE aux + 1-byte val (48000 → 000000bb80)
--   • NumChannels type 0x0002 → 4-byte BE aux + 1-byte val (2     → 0000000002)
--   • Duration    type 0x0004 → 8-byte BE aux + 1-byte val
--       (144000 = aux 562 + val 128 → 000000000000023280)
--
-- The reference hex below is the EXACT fixture TracksBA. Identity substitution
-- (same values) must reproduce it byte-for-byte; a different file's values must
-- land at the right offsets without disturbing the rest of the blob.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drt_audio_tracks_ba.lua
-- =============================================================================

local enc = require("exporters.drt_binary")

-- Verbatim BtAudioInfo TracksBA from resolve_authored_full.drp
-- (test_click_48k_stereo.wav: 48000 Hz, 2 ch, 144000 samples).
local REF =
    "00000001000000010000000200300000000c00000001930000000100000009" ..
    "000000100055006e0069007100750065004900640000000a00000000480063" ..
    "006600390036006400390065003400" ..
    "2d0038006300300066002d0034006200660033002d00380038003200330" ..
    "02d003900300065003300300065003500340037003200610062" ..
    "000000120053007400610072007400540069006d006500000006000000000" ..
    "0000000000000001400530061006d0070006c00650052006100740065" ..
    "00000003000000bb80" ..
    "00000016004e0075006d004300680061006e006e0065006c0073" ..
    "000000020000000002" ..
    "000000100049006400780054007200610063006b0000000200000000" ..
    "0000000010004400750072006100740069006f006e" ..
    "00000004000000000000023280" ..
    "0000000c0044006200540079007000650000000a0000000018004200740041" ..
    "007500640069006f0054007200610063006b" ..
    "000000120043006f006400650063004e0061006d0065" ..
    "0000000a0000000014004c0069006e006500610072002000500043004d" ..
    "0000001000420069007400440065007000740068000000030000000001"

local function check(cond, msg)
    assert(cond, "TracksBA substitution FAILED: " .. tostring(msg))
end

-- ── Identity: same values reproduce the fixture byte-for-byte ──────────────
local same = enc.substitute_audio_tracks_ba(REF,
    { sample_rate = 48000, num_channels = 2, duration_samples = 144000 })
check(same == REF,
    "identity substitution (48000/2/144000) must reproduce the fixture exactly")

-- ── Different file: 44100 Hz, mono, 88200 samples ──────────────────────────
local diff = enc.substitute_audio_tracks_ba(REF,
    { sample_rate = 44100, num_channels = 1, duration_samples = 88200 })
check(#diff == #REF,
    "all three values are same-width per their TLV type — blob length is stable")
-- 44100 = 0xAC44 → aux 0x000000ac, val 0x44
check(diff:find("000000ac44", 1, true) ~= nil,
    "SampleRate 44100 → 000000ac44")
-- 1 channel → aux 0, val 1
check(diff:find("0000000001", 1, true) ~= nil, "NumChannels 1 → 0000000001")
-- 88200 = 0x15888 → aux 0x158 (344), val 0x88 (136) → 16-hex aux + 88
check(diff:find("000000000000015888", 1, true) ~= nil,
    "Duration 88200 → 000000000000015888 (aux 344, val 136)")
-- the SampleRate/Duration changed, so the result must differ from the fixture
check(diff ~= REF, "changed values must change the blob")

-- ── Fail-fast on bad input ─────────────────────────────────────────────────
check(not pcall(enc.substitute_audio_tracks_ba, REF,
    { sample_rate = 0, num_channels = 2, duration_samples = 1 }),
    "zero sample_rate must loud-fail")
check(not pcall(enc.substitute_audio_tracks_ba, "deadbeef",
    { sample_rate = 48000, num_channels = 2, duration_samples = 144000 }),
    "a blob missing the named fields must loud-fail (no silent no-op)")

print("✅ test_drt_audio_tracks_ba.lua passed")
