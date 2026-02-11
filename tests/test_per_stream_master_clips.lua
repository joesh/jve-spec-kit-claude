#!/usr/bin/env luajit

-- Regression test: Per-stream master clips with correct timing units
--
-- Bug: Insert/Overwrite pulled timing from master clip's own fields (video frames)
-- and used those same values for both video AND audio clips. Audio clips have
-- rate=48000/1, interpreting video-frame values as samples → ~2000x duration error.
--
-- Fix: Pull timing from stream clips in source sequence:
-- - Video clip: source_in/out in frame units
-- - Audio clip: source_in/out in sample units
--
-- See MEMORY.md: "TODO: Per-Stream Master Clips Refactor"

require("test_env")

local Clip = require("models.clip")
local Media = require("models.media")
local Track = require("models.track")
local Sequence = require("models.sequence")
local database = require("core.database")
local command_manager = require("core.command_manager")
local uuid = require("uuid")
local frame_utils = require("core.frame_utils")

print("=== test_per_stream_master_clips.lua ===")

-- Set up test database
local db_path = "/tmp/jve/test_per_stream_master_clips.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
assert(db, "Need database connection")
db:exec(require('import_schema'))

-- Create test project
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
local project_id = "project"

-- Constants
local VIDEO_FPS_NUM = 24
local VIDEO_FPS_DEN = 1
local SAMPLE_RATE = 48000
local DURATION_MS = 10000  -- 10 seconds

-- Expected values
local EXPECTED_VIDEO_FRAMES = frame_utils.ms_to_frames(DURATION_MS, VIDEO_FPS_NUM, VIDEO_FPS_DEN)
local EXPECTED_AUDIO_SAMPLES = math.floor(DURATION_MS * SAMPLE_RATE / 1000 + 0.5)

print("\n--- Test: Clip model stream accessors ---")

-- Create a mock master clip with source sequence
local source_seq = Sequence.create("Test Source", project_id,
    {fps_numerator = VIDEO_FPS_NUM, fps_denominator = VIDEO_FPS_DEN},
    1920, 1080, {kind = "master"})
assert(source_seq:save(), "Failed to save source sequence")

local video_track = Track.create_video("V1", source_seq.id)
assert(video_track:save(), "Failed to save video track")

local audio_track = Track.create_audio("A1", source_seq.id)
assert(audio_track:save(), "Failed to save audio track")

-- Create master clip
local master_clip = Clip.create("Test Master", nil, {
    project_id = project_id,
    clip_kind = "master",
    master_clip_id = source_seq.id,
    timeline_start = 0,
    duration = EXPECTED_VIDEO_FRAMES,
    source_in = 0,
    source_out = EXPECTED_VIDEO_FRAMES,
    fps_numerator = VIDEO_FPS_NUM,
    fps_denominator = VIDEO_FPS_DEN,
})
assert(master_clip:save({skip_occlusion = true}), "Failed to save master clip")

-- Create video stream clip
local video_clip = Clip.create("Test Video", nil, {
    project_id = project_id,
    track_id = video_track.id,
    parent_clip_id = master_clip.id,
    owner_sequence_id = source_seq.id,
    timeline_start = 0,
    duration = EXPECTED_VIDEO_FRAMES,
    source_in = 0,
    source_out = EXPECTED_VIDEO_FRAMES,
    fps_numerator = VIDEO_FPS_NUM,
    fps_denominator = VIDEO_FPS_DEN,
})
assert(video_clip:save({skip_occlusion = true}), "Failed to save video clip")

-- Create audio stream clip (with sample units!)
local audio_clip = Clip.create("Test Audio", nil, {
    project_id = project_id,
    track_id = audio_track.id,
    parent_clip_id = master_clip.id,
    owner_sequence_id = source_seq.id,
    timeline_start = 0,
    duration = EXPECTED_AUDIO_SAMPLES,
    source_in = 0,
    source_out = EXPECTED_AUDIO_SAMPLES,
    fps_numerator = SAMPLE_RATE,
    fps_denominator = 1,
})
assert(audio_clip:save({skip_occlusion = true}), "Failed to save audio clip")

-- Test is_master_clip()
assert(master_clip:is_master_clip(), "Master clip should return true for is_master_clip()")
assert(not video_clip:is_master_clip(), "Video clip should return false for is_master_clip()")

-- Test video_stream()
local loaded_master = Clip.load(master_clip.id)
local vs = loaded_master:video_stream()
assert(vs, "video_stream() should return video clip")
assert(vs.id == video_clip.id, "video_stream() should return correct clip")
assert(vs.source_out == EXPECTED_VIDEO_FRAMES,
    string.format("Video stream source_out should be %d frames, got %d",
        EXPECTED_VIDEO_FRAMES, vs.source_out))

print("  ✓ video_stream() returns correct clip with frame units")

-- Test audio_streams()
local as = loaded_master:audio_streams()
assert(#as == 1, "audio_streams() should return 1 clip")
assert(as[1].id == audio_clip.id, "audio_streams() should return correct clip")
assert(as[1].source_out == EXPECTED_AUDIO_SAMPLES,
    string.format("Audio stream source_out should be %d samples, got %d",
        EXPECTED_AUDIO_SAMPLES, as[1].source_out))

print("  ✓ audio_streams() returns correct clip with sample units")

-- Test num_audio_streams()
assert(loaded_master:num_audio_streams() == 1, "num_audio_streams() should return 1")

print("  ✓ num_audio_streams() returns correct count")

print("\n--- Test: Timebase conversion ---")

-- Test frame_to_samples()
local test_frame = 100  -- 100 video frames
local expected_samples = math.floor(test_frame * SAMPLE_RATE * VIDEO_FPS_DEN / VIDEO_FPS_NUM)
local actual_samples = loaded_master:frame_to_samples(test_frame)

assert(actual_samples == expected_samples,
    string.format("frame_to_samples(%d) should return %d, got %s",
        test_frame, expected_samples, tostring(actual_samples)))

print(string.format("  ✓ frame_to_samples(%d) = %d samples", test_frame, actual_samples))

-- Test samples_to_frame()
local test_samples = 200000
local expected_frame = math.floor(test_samples * VIDEO_FPS_NUM / (VIDEO_FPS_DEN * SAMPLE_RATE))
local actual_frame = loaded_master:samples_to_frame(test_samples)

assert(actual_frame == expected_frame,
    string.format("samples_to_frame(%d) should return %d, got %s",
        test_samples, expected_frame, tostring(actual_frame)))

print(string.format("  ✓ samples_to_frame(%d) = %d frames", test_samples, actual_frame))

print("\n--- Test: Domain methods for stream sync ---")

-- Test set_all_streams_in() - set in point at frame 48 (2 seconds at 24fps)
local new_in_frame = 48
loaded_master:set_all_streams_in(new_in_frame)

-- Reload to verify persistence
loaded_master:invalidate_stream_cache()
local vs_after = loaded_master:video_stream()
local as_after = loaded_master:audio_streams()[1]

assert(vs_after.source_in == new_in_frame,
    string.format("Video source_in should be %d, got %d", new_in_frame, vs_after.source_in))

local expected_in_samples = loaded_master:frame_to_samples(new_in_frame)
assert(as_after.source_in == expected_in_samples,
    string.format("Audio source_in should be %d samples, got %d",
        expected_in_samples, as_after.source_in))

print(string.format("  ✓ set_all_streams_in(%d) → video=%d, audio=%d",
    new_in_frame, vs_after.source_in, as_after.source_in))

-- Test get_all_streams_in() - should return synced in point
local synced_in = loaded_master:get_all_streams_in()
assert(synced_in == new_in_frame,
    string.format("get_all_streams_in() should return %d, got %s",
        new_in_frame, tostring(synced_in)))

print("  ✓ get_all_streams_in() returns synced frame position")

print("\n--- Test: Verify duration equivalence ---")

-- Both video and audio streams should represent the same real-world duration
local video_duration_ms = EXPECTED_VIDEO_FRAMES * 1000 * VIDEO_FPS_DEN / VIDEO_FPS_NUM
local audio_duration_ms = EXPECTED_AUDIO_SAMPLES * 1000 / SAMPLE_RATE

print(string.format("  Video: %d frames → %.1f ms", EXPECTED_VIDEO_FRAMES, video_duration_ms))
print(string.format("  Audio: %d samples → %.1f ms", EXPECTED_AUDIO_SAMPLES, audio_duration_ms))

assert(math.abs(video_duration_ms - audio_duration_ms) < 1,
    "Video and audio durations should be equivalent")

print("  ✓ Stream durations are equivalent in milliseconds")

print("\n--- Test: Bug scenario - using video frames as audio samples ---")

-- If we incorrectly use video frames (240) with audio rate (48000/1):
local wrong_duration_ms = EXPECTED_VIDEO_FRAMES * 1000 / SAMPLE_RATE

print(string.format("  BUG: %d 'frames' interpreted as samples → %.3f ms (should be %.0f ms)",
    EXPECTED_VIDEO_FRAMES, wrong_duration_ms, DURATION_MS))

local error_ratio = DURATION_MS / wrong_duration_ms
print(string.format("  Error: %.0fx too short!", error_ratio))

assert(error_ratio > 100, "Bug should cause >100x error")
print("  ✓ Confirmed: wrong units cause catastrophic error")

print("\n--- Test: clip_edit_helper stream timing resolution ---")

local clip_edit_helper = require("core.clip_edit_helper")

-- Test resolve_video_stream_timing
local video_timing, err = clip_edit_helper.resolve_video_stream_timing(loaded_master, {})
assert(video_timing, "resolve_video_stream_timing should succeed: " .. tostring(err))
assert(video_timing.source_in == new_in_frame,
    string.format("Video timing source_in should be %d, got %d",
        new_in_frame, video_timing.source_in))
assert(video_timing.fps_numerator == VIDEO_FPS_NUM,
    string.format("Video timing fps_numerator should be %d, got %d",
        VIDEO_FPS_NUM, video_timing.fps_numerator))

print("  ✓ resolve_video_stream_timing returns frame units")

-- Test resolve_audio_stream_timing
local audio_timing, err2 = clip_edit_helper.resolve_audio_stream_timing(loaded_master, {})
assert(audio_timing, "resolve_audio_stream_timing should succeed: " .. tostring(err2))
assert(audio_timing.fps_numerator == SAMPLE_RATE,
    string.format("Audio timing fps_numerator should be %d, got %d",
        SAMPLE_RATE, audio_timing.fps_numerator))

print("  ✓ resolve_audio_stream_timing returns sample units")

-- Test with overrides (in video frames, converted to samples for audio)
local override_in = 72  -- 3 seconds at 24fps
local override_out = 168  -- 7 seconds at 24fps

local video_timing_o = clip_edit_helper.resolve_video_stream_timing(loaded_master, {
    source_in = override_in,
    source_out = override_out,
})
assert(video_timing_o.source_in == override_in)
assert(video_timing_o.source_out == override_out)
assert(video_timing_o.duration == override_out - override_in)

print(string.format("  ✓ Video with overrides: in=%d, out=%d, duration=%d frames",
    video_timing_o.source_in, video_timing_o.source_out, video_timing_o.duration))

local audio_timing_o = clip_edit_helper.resolve_audio_stream_timing(loaded_master, {
    source_in = override_in,
    source_out = override_out,
})
local expected_audio_in = loaded_master:frame_to_samples(override_in)
local expected_audio_out = loaded_master:frame_to_samples(override_out)
assert(audio_timing_o.source_in == expected_audio_in,
    string.format("Audio override in should be %d, got %d", expected_audio_in, audio_timing_o.source_in))
assert(audio_timing_o.source_out == expected_audio_out,
    string.format("Audio override out should be %d, got %d", expected_audio_out, audio_timing_o.source_out))

print(string.format("  ✓ Audio with overrides: in=%d, out=%d, duration=%d samples",
    audio_timing_o.source_in, audio_timing_o.source_out, audio_timing_o.duration))

-- Verify durations are equivalent
local video_override_ms = video_timing_o.duration * 1000 * VIDEO_FPS_DEN / VIDEO_FPS_NUM
local audio_override_ms = audio_timing_o.duration * 1000 / SAMPLE_RATE

assert(math.abs(video_override_ms - audio_override_ms) < 1,
    string.format("Override durations should match: video=%.1f ms, audio=%.1f ms",
        video_override_ms, audio_override_ms))

print(string.format("  ✓ Override durations equivalent: %.1f ms", video_override_ms))

-- Cleanup
local function cleanup_clip(id)
    local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    stmt:exec()
    stmt:finalize()
end

cleanup_clip(audio_clip.id)
cleanup_clip(video_clip.id)
cleanup_clip(master_clip.id)

local stmt = db:prepare("DELETE FROM tracks WHERE sequence_id = ?")
stmt:bind_value(1, source_seq.id)
stmt:exec()
stmt:finalize()

stmt = db:prepare("DELETE FROM sequences WHERE id = ?")
stmt:bind_value(1, source_seq.id)
stmt:exec()
stmt:finalize()

print("\n✅ test_per_stream_master_clips.lua passed")
