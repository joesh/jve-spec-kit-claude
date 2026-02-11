#!/usr/bin/env luajit
-- Tests for Sequence masterclip methods (IS-a refactor)
-- Tests: is_masterclip, video_stream, audio_streams, frame_to_samples, etc.

require("test_env")

local database = require('core.database')
local Sequence = require('models.sequence')
local Track = require('models.track')
local Clip = require('models.clip')
local Media = require('models.media')

print("=== Sequence Masterclip Methods Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_sequence_masterclip.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Insert Project
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))

-- Create Media
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/video1.mov",
    name = "Video 1",
    duration_frames = 2400,  -- 100 seconds at 24fps
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = 48000,
})
media:save(db)

--------------------------------------------------------------------------------
-- Test: is_masterclip() returns true for masterclip sequences
--------------------------------------------------------------------------------
print("Test: is_masterclip() for masterclip sequence")
local masterclip_seq = Sequence.create("Test Masterclip", "project",
    {fps_numerator = 24, fps_denominator = 1},
    1920, 1080,
    {kind = "masterclip"})
assert(masterclip_seq:save(), "Failed to save masterclip sequence")
assert(masterclip_seq:is_masterclip(), "is_masterclip() should return true for kind='masterclip'")
print("  ✓ is_masterclip() returns true for masterclip sequence")

--------------------------------------------------------------------------------
-- Test: is_masterclip() returns false for timeline sequences
--------------------------------------------------------------------------------
print("\nTest: is_masterclip() for timeline sequence")
local timeline_seq = Sequence.create("Test Timeline", "project",
    {fps_numerator = 24, fps_denominator = 1},
    1920, 1080)
assert(timeline_seq:save(), "Failed to save timeline sequence")
assert(not timeline_seq:is_masterclip(), "is_masterclip() should return false for timeline")
print("  ✓ is_masterclip() returns false for timeline sequence")

--------------------------------------------------------------------------------
-- Test: video_stream() returns video clip from masterclip
--------------------------------------------------------------------------------
print("\nTest: video_stream() returns video clip")

-- Add video track and clip to masterclip
local video_track = Track.create_video("V1", masterclip_seq.id, {index = 1})
assert(video_track:save(), "Failed to save video track")

local video_clip = Clip.create("Video Stream", "media_1", {
    track_id = video_track.id,
    owner_sequence_id = masterclip_seq.id,
    timeline_start = 0,
    duration = 2400,
    source_in = 0,
    source_out = 2400,
    fps_numerator = 24,
    fps_denominator = 1,
})
assert(video_clip:save({skip_occlusion = true}), "Failed to save video clip")

-- Invalidate cache and test
masterclip_seq:invalidate_stream_cache()
local video = masterclip_seq:video_stream()
assert(video, "video_stream() should return a clip")
assert(video.id == video_clip.id, "video_stream() should return the correct clip")
print("  ✓ video_stream() returns video clip")

--------------------------------------------------------------------------------
-- Test: audio_streams() returns audio clips from masterclip
--------------------------------------------------------------------------------
print("\nTest: audio_streams() returns audio clips")

-- Add audio track and clip to masterclip
local audio_track = Track.create_audio("A1", masterclip_seq.id, {index = 1})
assert(audio_track:save(), "Failed to save audio track")

local audio_clip = Clip.create("Audio Stream", "media_1", {
    track_id = audio_track.id,
    owner_sequence_id = masterclip_seq.id,
    timeline_start = 0,
    duration = 4800000,  -- 100 seconds in samples
    source_in = 0,
    source_out = 4800000,
    fps_numerator = 48000,  -- sample rate
    fps_denominator = 1,
})
assert(audio_clip:save({skip_occlusion = true}), "Failed to save audio clip")

masterclip_seq:invalidate_stream_cache()
local audios = masterclip_seq:audio_streams()
assert(#audios == 1, "audio_streams() should return 1 audio clip")
assert(audios[1].id == audio_clip.id, "audio_streams() should return the correct clip")
print("  ✓ audio_streams() returns audio clips")

--------------------------------------------------------------------------------
-- Test: frame_to_samples() converts video frames to audio samples
--------------------------------------------------------------------------------
print("\nTest: frame_to_samples() converts correctly")
-- At 24fps and 48000Hz sample rate:
-- 24 frames = 1 second = 48000 samples
-- 1 frame = 48000/24 = 2000 samples
local samples = masterclip_seq:frame_to_samples(24)
assert(samples == 48000, string.format("24 frames should be 48000 samples, got %d", samples))

samples = masterclip_seq:frame_to_samples(1)
assert(samples == 2000, string.format("1 frame should be 2000 samples, got %d", samples))

samples = masterclip_seq:frame_to_samples(0)
assert(samples == 0, string.format("0 frames should be 0 samples, got %d", samples))
print("  ✓ frame_to_samples() converts correctly")

--------------------------------------------------------------------------------
-- Test: samples_to_frame() converts audio samples to video frames
--------------------------------------------------------------------------------
print("\nTest: samples_to_frame() converts correctly")
local frames = masterclip_seq:samples_to_frame(48000)
assert(frames == 24, string.format("48000 samples should be 24 frames, got %d", frames))

frames = masterclip_seq:samples_to_frame(2000)
assert(frames == 1, string.format("2000 samples should be 1 frame, got %d", frames))

frames = masterclip_seq:samples_to_frame(0)
assert(frames == 0, string.format("0 samples should be 0 frames, got %d", frames))
print("  ✓ samples_to_frame() converts correctly")

--------------------------------------------------------------------------------
-- Test: video_stream() on non-masterclip asserts
--------------------------------------------------------------------------------
print("\nTest: video_stream() on non-masterclip asserts")
local ok, err = pcall(function()
    timeline_seq:video_stream()
end)
assert(not ok, "video_stream() on timeline should assert")
assert(err:match("is not a masterclip"), "Error should mention not a masterclip, got: " .. tostring(err))
print("  ✓ video_stream() asserts on non-masterclip")

--------------------------------------------------------------------------------
-- Test: audio_streams() on non-masterclip asserts
--------------------------------------------------------------------------------
print("\nTest: audio_streams() on non-masterclip asserts")
ok, err = pcall(function()
    timeline_seq:audio_streams()
end)
assert(not ok, "audio_streams() on timeline should assert")
assert(err:match("is not a masterclip"), "Error should mention not a masterclip, got: " .. tostring(err))
print("  ✓ audio_streams() asserts on non-masterclip")

--------------------------------------------------------------------------------
-- Test: frame_to_samples() with nil frame asserts
--------------------------------------------------------------------------------
print("\nTest: frame_to_samples() with nil frame asserts")
ok, err = pcall(function()
    masterclip_seq:frame_to_samples(nil)
end)
assert(not ok, "frame_to_samples(nil) should assert")
assert(err:match("frame must be a number"), "Error should mention frame type, got: " .. tostring(err))
print("  ✓ frame_to_samples() asserts on nil frame")

--------------------------------------------------------------------------------
-- Test: samples_to_frame() with nil samples asserts
--------------------------------------------------------------------------------
print("\nTest: samples_to_frame() with nil samples asserts")
ok, err = pcall(function()
    masterclip_seq:samples_to_frame(nil)
end)
assert(not ok, "samples_to_frame(nil) should assert")
assert(err:match("samples must be a number"), "Error should mention samples type, got: " .. tostring(err))
print("  ✓ samples_to_frame() asserts on nil samples")

--------------------------------------------------------------------------------
-- Test: num_audio_streams() returns correct count
--------------------------------------------------------------------------------
print("\nTest: num_audio_streams() returns correct count")
local count = masterclip_seq:num_audio_streams()
assert(count == 1, string.format("Should have 1 audio stream, got %d", count))
print("  ✓ num_audio_streams() returns correct count")

print("\n✅ test_sequence_masterclip_methods.lua passed")
