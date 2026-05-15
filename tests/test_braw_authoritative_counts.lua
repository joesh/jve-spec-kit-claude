#!/usr/bin/env luajit
--- BRAW probe must surface SDK-authoritative frame counts
---
--- Domain contract: when the BRAW SDK reports a clip's frame_count or
--- audio_sample_count, those are AUTHORITATIVE. They came directly out
--- of the codec metadata and reflect what the decoder will actually
--- produce frame-for-frame.
---
--- Why this matters: BRAW @ 23.976 fps records audio at the NOMINAL
--- 24fps rate (2000 audio samples per video frame at 48kHz), not at
--- the pulldown rate (2002 samples/frame). Deriving audio_sample_count
--- from `duration_us * sample_rate / 1_000_000` — where duration_us
--- itself was computed as `frame_count * 1000000 * 1001 / 24000` —
--- overshoots by ~1‰ on every 23.976 BRAW. For a 1070-frame clip the
--- error is ~2140 samples (~45ms of audio) the decoder isn't actually
--- holding.
---
--- Observed (2026-05-15) on Blackmagic SDK probe output:
---   A004_05231552_C024.braw (285 frames @ 23.976): SDK reports 570000
---     audio samples; duration-derived would give 570570 (+570 drift).
---   A004_05231552_C023.braw (383 frames): SDK 766000; derived 766766.
---
--- Contract: EMP.MEDIA_PROBE(braw) must populate
---   info.video_frame_count    -- SDK clip->GetFrameCount()
---   info.audio_sample_count   -- SDK audio interface sample count
--- as non-negative integers (or nil if BRAW SDK didn't expose them).
--- Downstream consumers (media_relinker, importers) must prefer these
--- over the lossy duration_us round-trip.
---
--- Integration test — runs inside JVEEditor --test mode so the BRAW SDK
--- loads and probes real fixture media.

require('test_env')

print("=== test_braw_authoritative_counts.lua ===")

local EMP = qt_constants and qt_constants.EMP
if not (EMP and EMP.MEDIA_PROBE) then
    print("SKIP: EMP.MEDIA_PROBE binding not available (not in --test mode)")
    return
end

-- Fixture: 23.976fps BRAW where the duration round-trip overshoots
-- audio_sample_count. Path is repo-relative so the test runs anywhere
-- the fixture tree is in place.
local repo_root = os.getenv("JVE_REPO_ROOT")
    or "/Users/joe/Local/jve-spec-kit-claude"
local fixture_dir = repo_root .. "/tests/fixtures/media/anamnesis/"
    .. "2026-02-28-anamnesis joe edit-mm/Volumes/AnamBack4 Joe/Footage/"

-- 25fps BRAW: round-number sample count, derivation happens to match —
-- still useful as a positive check that the new field is populated.
local braw_25fps = fixture_dir .. "Day 15/A001/A001_07240013_C018.braw"

-- Helper: check file exists, otherwise SKIP (fixtures are large and
-- not always cloned).
local function file_exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

if not file_exists(braw_25fps) then
    print("SKIP: BRAW fixture not present at " .. braw_25fps)
    return
end

print("\n--- Case 1: 25fps BRAW (round-number alignment) ---")
local info, err = EMP.MEDIA_PROBE(braw_25fps)
assert(info, string.format("MEDIA_PROBE failed: %s", tostring(err)))
assert(info.has_video, "fixture must have video")
assert(info.has_audio, "fixture must have audio")

assert(info.video_frame_count ~= nil, string.format(
    "BRAW probe must surface video_frame_count (SDK clip->GetFrameCount). "
    .. "Got nil. duration_us round-trip is lossy at non-integer fps."))
assert(type(info.video_frame_count) == "number"
    and info.video_frame_count == math.floor(info.video_frame_count)
    and info.video_frame_count > 0, string.format(
    "video_frame_count must be a positive integer, got %s",
    tostring(info.video_frame_count)))

assert(info.audio_sample_count ~= nil, string.format(
    "BRAW probe with audio must surface audio_sample_count (SDK audio "
    .. "interface). Got nil."))
assert(type(info.audio_sample_count) == "number"
    and info.audio_sample_count == math.floor(info.audio_sample_count)
    and info.audio_sample_count > 0, string.format(
    "audio_sample_count must be a positive integer, got %s",
    tostring(info.audio_sample_count)))

print(string.format("  ✓ video_frame_count=%d audio_sample_count=%d (fps=%d/%d, sr=%d)",
    info.video_frame_count, info.audio_sample_count,
    info.fps_num, info.fps_den, info.audio_sample_rate))

-- 23.976fps BRAW: this is the case where the round-trip lies. SDK gives
-- 570000; duration-derived gives 570570. The test FAILS without the
-- authoritative field because every audio-extent consumer trusts the
-- derived count and reads past the actual audio sample window.
print("\n--- Case 2: 23.976fps BRAW (round-trip overshoots) ---")
local braw_2398 = "/Users/joe/Library/Mobile Documents/com~apple~CloudDocs/"
    .. "frames for BM Support/A004_05231552_C024.braw"

if not file_exists(braw_2398) then
    print("SKIP Case 2: 23.976 BRAW fixture not present at " .. braw_2398)
else
    local info2, err2 = EMP.MEDIA_PROBE(braw_2398)
    assert(info2, string.format("MEDIA_PROBE failed: %s", tostring(err2)))
    assert(info2.fps_num == 24000 and info2.fps_den == 1001,
        "fixture must be 23.976 fps")

    -- Derivation per current media_relinker.probe_result_from_emp_info:
    local derived_audio = math.floor(
        info2.duration_us * info2.audio_sample_rate / 1e6 + 0.5)

    -- The SDK-authoritative number must NOT equal the derived number —
    -- if they did, this fixture wouldn't exercise the bug.
    assert(info2.audio_sample_count ~= nil,
        "BRAW 23.976 probe must surface audio_sample_count")
    assert(info2.audio_sample_count ~= derived_audio, string.format(
        "Fixture invariant: SDK audio_sample_count (%d) must differ from "
        .. "derived-from-duration_us (%d) — otherwise the round-trip is "
        .. "not exercised and the test is uninformative. If you've "
        .. "changed BRAW fixtures, pick one where the SDK reports a "
        .. "round-number sample count at 23.976 fps.",
        info2.audio_sample_count, derived_audio))

    -- The shape of the BRAW bug: derivation OVERSHOOTS by the
    -- pulldown factor 1001/1000. So derived > authoritative.
    assert(derived_audio > info2.audio_sample_count, string.format(
        "Expected derived (%d) > SDK (%d) at 23.976: derivation uses "
        .. "video duration which overshoots because BRAW audio is at "
        .. "the nominal rate.",
        derived_audio, info2.audio_sample_count))

    print(string.format(
        "  ✓ SDK audio_sample_count=%d, derived=%d (drift=%d at 23.976) — "
        .. "downstream must use the SDK value.",
        info2.audio_sample_count, derived_audio,
        derived_audio - info2.audio_sample_count))
end

print("\n✅ test_braw_authoritative_counts.lua passed")
