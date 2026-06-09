#!/usr/bin/env luajit

-- 018: the prproj parser must stamp `native_rate` on every clip in its
-- parse_result so importer_core's audio path can convert source_in
-- (file-native samples) into (master.fps frame, master-clock-tick
-- subframe) at the Clip write boundary. Pre-fix the parser delivered
-- source_in correctly but omitted native_rate, and importer_core
-- asserted at line 782 ("clip missing native_rate") for every audio clip.
--
-- This test pins the parser-side 018 contract only. The full
-- parser → DB → resolver round-trip is blocked by a separate
-- pre-existing bug (prproj parser doesn't seed media TC origin →
-- ensure_master fails when source files aren't present on disk).
-- That hole is tracked separately; this test deliberately stays narrow
-- so the 018 contract has its own regression pin independent of the
-- broader prproj readiness story.

require('test_env')

local prproj   = require("importers.prproj_importer")
local test_env = require("test_env")

local fixture = test_env.require_fixture(
    "tests/fixtures/premiere/2026-03-20-anamnesis joe edit.prproj")

print("\n=== prproj 018 parser native_rate contract ===")

local parse_result = prproj.parse_prproj_file(fixture)
assert(parse_result and parse_result.success, string.format(
    "parse_prproj_file failed: %s", tostring(parse_result and parse_result.error)))
assert(type(parse_result.timelines) == "table" and #parse_result.timelines > 0,
    "fixture must yield at least one parsed sequence")

local audio_seen, video_seen = 0, 0
for _, seq in ipairs(parse_result.timelines) do
    assert(type(seq.tracks) == "table",
        string.format("sequence '%s' has no tracks table", tostring(seq.name)))
    for _, tr in ipairs(seq.tracks) do
        assert(tr.type == "VIDEO" or tr.type == "AUDIO", string.format(
            "track type must be VIDEO or AUDIO; got %s", tostring(tr.type)))
        assert(type(tr.clips) == "table", string.format(
            "%s track in sequence '%s' has no clips table (parser must " ..
            "deliver {} when empty, not nil)", tr.type, tostring(seq.name)))
        for _, clip in ipairs(tr.clips) do
            assert(type(clip.native_rate) == "number" and clip.native_rate > 0,
                string.format(
                    "%s track clip '%s' missing/invalid native_rate (got %s) — "
                    .. "importer_core asserts on this at write time (FR-008)",
                    tr.type, tostring(clip.name), tostring(clip.native_rate)))
            if tr.type == "AUDIO" then
                audio_seen = audio_seen + 1
                -- Audio native_rate must be a plausible sample rate
                -- (8 kHz floor catches any accidental frame-rate value
                -- of e.g. 24 or 60 landing here).
                assert(clip.native_rate >= 8000, string.format(
                    "AUDIO clip '%s' has native_rate=%d — looks like a frame "
                    .. "rate, not a sample rate. Parser must pass the file's "
                    .. "audio_sample_rate as native_rate for AUDIO tracks.",
                    tostring(clip.name), clip.native_rate))
            else
                video_seen = video_seen + 1
                -- Video native_rate must be a plausible frame rate.
                -- 1000 fps ceiling catches any sample-rate (48000+)
                -- accidentally landing here.
                assert(clip.native_rate < 1000, string.format(
                    "VIDEO clip '%s' has native_rate=%d — looks like a sample "
                    .. "rate, not a frame rate. Parser must pass round(fps) as "
                    .. "native_rate for VIDEO tracks.",
                    tostring(clip.name), clip.native_rate))
            end
        end
    end
end

assert(audio_seen > 0,
    "fixture must contain at least one AUDIO clip to exercise the 018 contract")
assert(video_seen > 0,
    "fixture must contain at least one VIDEO clip for the cross-kind sanity check")

print(string.format(
    "  PASS: native_rate stamped on every clip (%d audio, %d video) "
    .. "in plausible-rate ranges per track type",
    audio_seen, video_seen))

print("✅ test_prproj_018_subframe_conversion.lua passed")
