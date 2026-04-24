#!/usr/bin/env luajit
-- Regression: DRP import must record audio_sample_rate for A/V media
-- (video files with an embedded audio stream), not only audio-only media.
--
-- Domain behavior: after importing a project where a media file has both
-- a video track (BtVideoInfo.Time → num_frames) AND an audio track
-- (BtAudioInfo.TracksBA → sample_rate, duration_samples), the resulting
-- media record must describe BOTH streams — its duration/frame_rate come
-- from the video stream, and its audio_sample_rate is the audio stream's
-- sample rate. Dropping the audio sample rate leaves waveform display,
-- playback engine audio math, and any other audio-aware consumer unable
-- to find the file's audio.

require("test_env")

local drp = require("importers.drp_importer")

print("=== test_drp_av_media_sample_rate.lua ===")

-- Three representative pmcs from a real production DRP:
--   av      — A/V file: has both num_frames and audio_duration
--   av_hz   — A/V file at 44.1kHz, to rule out hard-coded 48000 assumptions
--   vo     — video-only file: num_frames, no audio_duration
--   ao     — audio-only file: audio_duration, no num_frames
local pmcs = {
    av = {
        num_frames   = 6000,  -- 4 minutes at 25fps
        frame_rate   = 25,
        audio_duration = { samples = 11520000, sample_rate = 48000 },
    },
    av_hz = {
        num_frames   = 1500,
        frame_rate   = 25,
        audio_duration = { samples = 2646000, sample_rate = 44100 },
    },
    vo = {
        num_frames = 240,
        frame_rate = 24,
    },
    ao = {
        audio_duration = { samples = 480000, sample_rate = 48000 },
    },
}

local function fresh_entry()
    return { alt_paths = {} }
end

local function apply(pmc)
    local e = fresh_entry()
    drp._apply_pmc_metadata(e, pmc)
    return e
end

-- ─────────────────────────────────────────────────────────────────────
-- A/V file (the bug case): must carry BOTH video-derived duration AND
-- audio sample rate. The video stream drives duration/frame_rate; the
-- audio stream drives audio_sample_rate.
-- ─────────────────────────────────────────────────────────────────────
local av = apply(pmcs.av)
assert(av.duration == 6000, string.format(
    "A/V: duration should be the video frame count (6000), got %s", tostring(av.duration)))
assert(av.frame_rate == 25, string.format(
    "A/V: frame_rate should be the video rate (25), got %s", tostring(av.frame_rate)))
assert(av.audio_sample_rate == 48000, string.format(
    "A/V: audio_sample_rate must be populated (48000) even when num_frames > 0, got %s",
    tostring(av.audio_sample_rate)))
print("  ✓ A/V file: video duration + audio sample rate both recorded")

local av_hz = apply(pmcs.av_hz)
assert(av_hz.audio_sample_rate == 44100, string.format(
    "A/V 44.1k: audio_sample_rate should be 44100, got %s", tostring(av_hz.audio_sample_rate)))
print("  ✓ A/V file: audio sample rate reflects the audio stream, not a fixed default")

-- ─────────────────────────────────────────────────────────────────────
-- Video-only file: no audio_sample_rate (nothing to record).
-- ─────────────────────────────────────────────────────────────────────
local vo = apply(pmcs.vo)
assert(vo.duration == 240, "video-only: duration from num_frames")
assert(vo.frame_rate == 24, "video-only: frame_rate from video")
assert(vo.audio_sample_rate == nil,
    "video-only: audio_sample_rate must be nil (file has no audio)")
print("  ✓ Video-only: no audio_sample_rate recorded")

-- ─────────────────────────────────────────────────────────────────────
-- Audio-only file: audio_sample_rate set; duration/frame_rate come from
-- the audio stream because there's no video stream.
-- ─────────────────────────────────────────────────────────────────────
local ao = apply(pmcs.ao)
assert(ao.duration == 480000,
    string.format("audio-only: duration in samples (480000), got %s", tostring(ao.duration)))
assert(ao.audio_sample_rate == 48000,
    string.format("audio-only: audio_sample_rate = 48000, got %s", tostring(ao.audio_sample_rate)))
assert(ao.frame_rate == 48000, string.format(
    "audio-only: frame_rate stands in for sample rate (48000), got %s", tostring(ao.frame_rate)))
print("  ✓ Audio-only: sample rate recorded, duration in samples")

print("\n✅ test_drp_av_media_sample_rate.lua passed")
