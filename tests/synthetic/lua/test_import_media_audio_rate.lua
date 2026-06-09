#!/usr/bin/env luajit

-- Regression: ImportMedia must create audio clips with sample-rate-based coords
--
-- Bug: ImportMedia created audio clips in master sequences with VIDEO fps rate
-- and source coords in VIDEO frames. When Insert copies these to timeline with
-- rate=48000/1, the coords don't match → audio duration wildly wrong.
--
-- Fix: Audio clips in master sequences use sample_rate/1 as rate, with source
-- coords converted to samples.

require("test_env")

local frame_utils = require("core.frame_utils")

print("=== test_import_media_audio_rate.lua ===")

print("\n--- Test: Audio clip duration conversion formula ---")

-- Test the conversion formula used in import_media.lua:
-- Video: duration_frames = frame_utils.ms_to_frames(duration_ms, fps_num, fps_den)
-- Audio: duration_samples = duration_ms * sample_rate / 1000

-- Example: 10 second clip at 24fps
local duration_ms = 10000  -- 10 seconds
local fps_num = 24
local fps_den = 1
local sample_rate = 48000

local duration_frames = frame_utils.ms_to_frames(duration_ms, fps_num, fps_den)
local duration_samples = math.floor(duration_ms * sample_rate / 1000 + 0.5)

print(string.format("  10s clip: %d frames at %d fps, %d samples at %d Hz",
    duration_frames, fps_num, duration_samples, sample_rate))

-- Verify video duration
assert(duration_frames == 240, string.format("Expected 240 frames, got %d", duration_frames))

-- Verify audio duration
assert(duration_samples == 480000, string.format("Expected 480000 samples, got %d", duration_samples))

-- Verify they both represent the same real-world duration
local video_duration_ms = duration_frames * 1000 * fps_den / fps_num
local audio_duration_ms = duration_samples * 1000 / sample_rate

print(string.format("  Video → %.1f ms, Audio → %.1f ms", video_duration_ms, audio_duration_ms))
assert(math.abs(video_duration_ms - audio_duration_ms) < 1, "Durations should match")

print("✓ Conversion formulas produce equivalent durations")

print("\n--- Test: Bug scenario - using video frames as audio samples ---")

-- If we incorrectly use video frames (240) with audio rate (48000/1):
local wrong_duration_ms = duration_frames * 1000 / sample_rate  -- 240 / 48000 * 1000 = 5ms

print(string.format("  BUG: %d 'frames' interpreted as samples → %.3f ms (should be 10000 ms)",
    duration_frames, wrong_duration_ms))

local error_ratio = duration_ms / wrong_duration_ms
print(string.format("  Error: %.0fx too short!", error_ratio))

assert(error_ratio > 100, "Bug should cause >100x error")
print("✓ Confirmed: wrong units cause catastrophic error")

-- Behavioral tests for ensure_masterclip audio rate are in test_ensure_masterclip.lua
-- (verifies audio clips get fps_numerator=sample_rate, source coords in samples)

print("\n✅ test_import_media_audio_rate.lua passed")
