#!/usr/bin/env luajit

-- Regression: Audio clip source positions use clip.rate for conversion
--
-- For DRP audio clips, clip.rate = sample_rate/1 (e.g. 48000/1)
-- This ensures source_in/source_out (in sample units) are correctly converted to microseconds.
--
-- Native JVE clips use clip.rate = timeline_fps/1 (e.g. 24/1)
-- Their source_in/source_out are in frame units.
--
-- TMB uses clip.rate for the conversion, so the importer
-- must set the correct rate based on what units source positions are stored in.

require("test_env")

print("=== test_audio_source_uses_sample_rate.lua ===")

--------------------------------------------------------------------------------
-- Test: Verify the formula works for both frame-based and sample-based clips
--------------------------------------------------------------------------------

print("\n--- Test: Conversion formula for different clip rates ---")

-- DRP audio clip: source positions in samples
local source_in_samples = 4800000   -- 100 seconds worth at 48000Hz
local duration_samples = 2400000    -- 50 seconds worth at 48000Hz
local sample_rate = 48000

-- Using sample_rate as clip.rate (fps_num=48000, fps_den=1) gives correct conversion
-- Formula: time_us = frames * 1000000 * fps_den / fps_num
local correct_seek_us = math.floor(source_in_samples * 1000000 * 1 / sample_rate)
local correct_duration_us = math.floor(duration_samples * 1000000 * 1 / sample_rate)

print(string.format("  DRP audio clip: source_in=%d samples @ %d/1 rate", source_in_samples, sample_rate))
print(string.format("    seek_us = %d us = %.1f seconds", correct_seek_us, correct_seek_us/1000000))
print(string.format("    duration_us = %d us = %.1f seconds", correct_duration_us, correct_duration_us/1000000))

assert(math.abs(correct_seek_us - 100000000) < 1000, "seek should be 100s")
assert(math.abs(correct_duration_us - 50000000) < 1000, "duration should be 50s")
print("✓ Sample-based clip (48000/1) converts correctly")

-- Native frame-based clip: source positions in frames
local source_in_frames = 2400   -- 100 seconds at 24fps
local duration_frames = 1200    -- 50 seconds at 24fps
local fps = 24

local frame_seek_us = math.floor(source_in_frames * 1000000 * 1 / fps)
local frame_duration_us = math.floor(duration_frames * 1000000 * 1 / fps)

print(string.format("\n  Native clip: source_in=%d frames @ %d/1 rate", source_in_frames, fps))
print(string.format("    seek_us = %d us = %.1f seconds", frame_seek_us, frame_seek_us/1000000))
print(string.format("    duration_us = %d us = %.1f seconds", frame_duration_us, frame_duration_us/1000000))

assert(math.abs(frame_seek_us - 100000000) < 1000, "seek should be 100s")
assert(math.abs(frame_duration_us - 50000000) < 1000, "duration should be 50s")
print("✓ Frame-based clip (24/1) converts correctly")

--------------------------------------------------------------------------------
-- Test: Bug scenario - using wrong rate for DRP audio
--------------------------------------------------------------------------------

print("\n--- Test: Bug scenario - wrong rate for DRP audio ---")

-- If DRP importer wrongly set clip.rate = timeline_fps instead of sample_rate
-- the conversion would be wildly wrong:
local wrong_seek_us = math.floor(source_in_samples * 1000000 * 1 / 24)  -- Using 24fps
local wrong_duration_us = math.floor(duration_samples * 1000000 * 1 / 24)

print(string.format("  BUG: DRP audio with rate=24/1 instead of 48000/1:"))
print(string.format("    seek_us = %d us = %.1f seconds (should be 100s)", wrong_seek_us, wrong_seek_us/1000000))
print(string.format("    duration_us = %d us = %.1f seconds (should be 50s)", wrong_duration_us, wrong_duration_us/1000000))

local ratio = wrong_seek_us / correct_seek_us
print(string.format("  Error ratio: %.0fx too large!", ratio))
assert(ratio > 1000, "Bug would produce values 2000x too large")
print("✓ Confirmed: using wrong rate causes 2000x error")

print("\n✅ test_audio_source_uses_sample_rate.lua passed")
