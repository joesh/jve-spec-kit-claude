#!/usr/bin/env luajit

-- NSF Error Path Tests for Per-Stream Master Clips
--
-- Tests error handling and edge cases:
-- - nil inputs to domain methods
-- - missing stream clips
-- - audio-only master clips
-- - type validation

require("test_env")

local Clip = require("models.clip")
local Track = require("models.track")
local Sequence = require("models.sequence")
local database = require("core.database")
local clip_edit_helper = require("core.clip_edit_helper")

print("=== test_per_stream_master_clips_errors.lua ===")

-- Set up test database
local db_path = "/tmp/jve/test_per_stream_master_clips_errors.db"
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
local DURATION_FRAMES = 240
local DURATION_SAMPLES = 480000

print("\n--- Test: frame_to_samples with nil input ---")

local function test_frame_to_samples_nil_input()
    -- Create master clip without audio
    local source_seq = Sequence.create("Video Only", project_id,
        {fps_numerator = VIDEO_FPS_NUM, fps_denominator = VIDEO_FPS_DEN},
        1920, 1080, {kind = "master"})
    assert(source_seq:save())

    local video_track = Track.create_video("V1", source_seq.id)
    assert(video_track:save())

    local master_clip = Clip.create("Video Only Master", nil, {
        project_id = project_id,
        clip_kind = "master",
        source_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(master_clip:save({skip_occlusion = true}))

    -- Create video clip only
    local video_clip = Clip.create("Video", nil, {
        project_id = project_id,
        track_id = video_track.id,
        parent_clip_id = master_clip.id,
        owner_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(video_clip:save({skip_occlusion = true}))

    -- Load and test
    local loaded = Clip.load(master_clip.id)

    -- frame_to_samples should return nil when no audio stream
    local result = loaded:frame_to_samples(100)
    assert(result == nil, "frame_to_samples should return nil when no audio streams")

    print("  ✓ frame_to_samples returns nil when no audio streams")

    -- Cleanup
    db:exec("DELETE FROM clips WHERE id = '" .. video_clip.id .. "'")
    db:exec("DELETE FROM clips WHERE id = '" .. master_clip.id .. "'")
    db:exec("DELETE FROM tracks WHERE sequence_id = '" .. source_seq.id .. "'")
    db:exec("DELETE FROM sequences WHERE id = '" .. source_seq.id .. "'")
end

test_frame_to_samples_nil_input()

print("\n--- Test: frame_to_samples type validation ---")

local function test_frame_to_samples_type_check()
    -- Create a minimal master clip for testing
    local source_seq = Sequence.create("Type Test", project_id,
        {fps_numerator = VIDEO_FPS_NUM, fps_denominator = VIDEO_FPS_DEN},
        1920, 1080, {kind = "master"})
    assert(source_seq:save())

    local master_clip = Clip.create("Type Test Master", nil, {
        project_id = project_id,
        clip_kind = "master",
        source_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(master_clip:save({skip_occlusion = true}))

    local loaded = Clip.load(master_clip.id)

    -- Test with string input
    local ok, err = pcall(function()
        loaded:frame_to_samples("not a number")
    end)
    assert(not ok, "frame_to_samples should reject string input")
    assert(err:match("must be a number"), "Error message should mention type requirement")

    print("  ✓ frame_to_samples rejects non-number input")

    -- Cleanup
    db:exec("DELETE FROM clips WHERE id = '" .. master_clip.id .. "'")
    db:exec("DELETE FROM sequences WHERE id = '" .. source_seq.id .. "'")
end

test_frame_to_samples_type_check()

print("\n--- Test: set_in/set_out type validation ---")

local function test_set_in_out_type_check()
    local source_seq = Sequence.create("Set Test", project_id,
        {fps_numerator = VIDEO_FPS_NUM, fps_denominator = VIDEO_FPS_DEN},
        1920, 1080, {kind = "master"})
    assert(source_seq:save())

    local video_track = Track.create_video("V1", source_seq.id)
    assert(video_track:save())

    local video_clip = Clip.create("Video", nil, {
        project_id = project_id,
        track_id = video_track.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(video_clip:save({skip_occlusion = true}))

    local loaded = Clip.load(video_clip.id)

    -- Test set_in with nil
    local ok, err = pcall(function()
        loaded:set_in(nil)
    end)
    assert(not ok, "set_in should reject nil input")
    assert(err:match("must be a number"), "Error should mention type requirement")

    -- Test set_out with string
    ok, err = pcall(function()
        loaded:set_out("not a number")
    end)
    assert(not ok, "set_out should reject string input")
    assert(err:match("must be a number"), "Error should mention type requirement")

    print("  ✓ set_in/set_out reject non-number inputs")

    -- Cleanup
    db:exec("DELETE FROM clips WHERE id = '" .. video_clip.id .. "'")
    db:exec("DELETE FROM tracks WHERE sequence_id = '" .. source_seq.id .. "'")
    db:exec("DELETE FROM sequences WHERE id = '" .. source_seq.id .. "'")
end

test_set_in_out_type_check()

print("\n--- Test: set_all_streams_in type validation ---")

local function test_set_all_streams_type_check()
    local source_seq = Sequence.create("All Streams Test", project_id,
        {fps_numerator = VIDEO_FPS_NUM, fps_denominator = VIDEO_FPS_DEN},
        1920, 1080, {kind = "master"})
    assert(source_seq:save())

    local master_clip = Clip.create("Master", nil, {
        project_id = project_id,
        clip_kind = "master",
        source_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(master_clip:save({skip_occlusion = true}))

    local loaded = Clip.load(master_clip.id)

    -- Test set_all_streams_in with table
    local ok, err = pcall(function()
        loaded:set_all_streams_in({frame = 100})
    end)
    assert(not ok, "set_all_streams_in should reject table input")
    assert(err:match("must be a number"), "Error should mention type requirement")

    -- Test set_all_streams_out with nil
    ok, err = pcall(function()
        loaded:set_all_streams_out(nil)
    end)
    assert(not ok, "set_all_streams_out should reject nil input")

    print("  ✓ set_all_streams_in/out reject non-number inputs")

    -- Cleanup
    db:exec("DELETE FROM clips WHERE id = '" .. master_clip.id .. "'")
    db:exec("DELETE FROM sequences WHERE id = '" .. source_seq.id .. "'")
end

test_set_all_streams_type_check()

print("\n--- Test: resolve_video_stream_timing with no video ---")

local function test_resolve_video_timing_no_video()
    -- Create audio-only master clip
    local source_seq = Sequence.create("Audio Only", project_id,
        {fps_numerator = VIDEO_FPS_NUM, fps_denominator = VIDEO_FPS_DEN},
        1920, 1080, {kind = "master"})
    assert(source_seq:save())

    local audio_track = Track.create_audio("A1", source_seq.id)
    assert(audio_track:save())

    local master_clip = Clip.create("Audio Only Master", nil, {
        project_id = project_id,
        clip_kind = "master",
        source_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_SAMPLES,
        source_in = 0,
        source_out = DURATION_SAMPLES,
        fps_numerator = SAMPLE_RATE,
        fps_denominator = 1,
    })
    assert(master_clip:save({skip_occlusion = true}))

    -- Create audio clip only
    local audio_clip = Clip.create("Audio", nil, {
        project_id = project_id,
        track_id = audio_track.id,
        parent_clip_id = master_clip.id,
        owner_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_SAMPLES,
        source_in = 0,
        source_out = DURATION_SAMPLES,
        fps_numerator = SAMPLE_RATE,
        fps_denominator = 1,
    })
    assert(audio_clip:save({skip_occlusion = true}))

    local loaded = Clip.load(master_clip.id)

    -- Should return nil, error message
    local timing, err = clip_edit_helper.resolve_video_stream_timing(loaded, {})
    assert(timing == nil, "resolve_video_stream_timing should return nil for audio-only clip")
    assert(err == "No video stream in master clip", "Error message should explain the issue")

    print("  ✓ resolve_video_stream_timing returns error for audio-only clip")

    -- Cleanup
    db:exec("DELETE FROM clips WHERE id = '" .. audio_clip.id .. "'")
    db:exec("DELETE FROM clips WHERE id = '" .. master_clip.id .. "'")
    db:exec("DELETE FROM tracks WHERE sequence_id = '" .. source_seq.id .. "'")
    db:exec("DELETE FROM sequences WHERE id = '" .. source_seq.id .. "'")
end

test_resolve_video_timing_no_video()

print("\n--- Test: resolve_audio_stream_timing with no audio ---")

local function test_resolve_audio_timing_no_audio()
    -- Create video-only master clip
    local source_seq = Sequence.create("Video Only", project_id,
        {fps_numerator = VIDEO_FPS_NUM, fps_denominator = VIDEO_FPS_DEN},
        1920, 1080, {kind = "master"})
    assert(source_seq:save())

    local video_track = Track.create_video("V1", source_seq.id)
    assert(video_track:save())

    local master_clip = Clip.create("Video Only Master", nil, {
        project_id = project_id,
        clip_kind = "master",
        source_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(master_clip:save({skip_occlusion = true}))

    local video_clip = Clip.create("Video", nil, {
        project_id = project_id,
        track_id = video_track.id,
        parent_clip_id = master_clip.id,
        owner_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(video_clip:save({skip_occlusion = true}))

    local loaded = Clip.load(master_clip.id)

    -- Should return nil, error message
    local timing, err = clip_edit_helper.resolve_audio_stream_timing(loaded, {})
    assert(timing == nil, "resolve_audio_stream_timing should return nil for video-only clip")
    assert(err == "No audio streams in master clip", "Error message should explain the issue")

    print("  ✓ resolve_audio_stream_timing returns error for video-only clip")

    -- Cleanup
    db:exec("DELETE FROM clips WHERE id = '" .. video_clip.id .. "'")
    db:exec("DELETE FROM clips WHERE id = '" .. master_clip.id .. "'")
    db:exec("DELETE FROM tracks WHERE sequence_id = '" .. source_seq.id .. "'")
    db:exec("DELETE FROM sequences WHERE id = '" .. source_seq.id .. "'")
end

test_resolve_audio_timing_no_audio()

print("\n--- Test: is_master_clip on non-master clip ---")

local function test_is_master_clip_false()
    local source_seq = Sequence.create("Regular Seq", project_id,
        {fps_numerator = VIDEO_FPS_NUM, fps_denominator = VIDEO_FPS_DEN},
        1920, 1080)  -- No kind = "master"
    assert(source_seq:save())

    local video_track = Track.create_video("V1", source_seq.id)
    assert(video_track:save())

    -- Create a timeline clip (not a master clip)
    local timeline_clip = Clip.create("Timeline Clip", nil, {
        project_id = project_id,
        clip_kind = "timeline",
        track_id = video_track.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(timeline_clip:save({skip_occlusion = true}))

    local loaded = Clip.load(timeline_clip.id)

    assert(loaded:is_master_clip() == false, "Timeline clip should not be master clip")
    assert(loaded:video_stream() == nil, "Timeline clip should have no video_stream")
    assert(#loaded:audio_streams() == 0, "Timeline clip should have no audio_streams")

    print("  ✓ is_master_clip returns false for timeline clips")

    -- Cleanup
    db:exec("DELETE FROM clips WHERE id = '" .. timeline_clip.id .. "'")
    db:exec("DELETE FROM tracks WHERE sequence_id = '" .. source_seq.id .. "'")
    db:exec("DELETE FROM sequences WHERE id = '" .. source_seq.id .. "'")
end

test_is_master_clip_false()

print("\n--- Test: get_all_streams_in returns nil when not synced ---")

local function test_get_all_streams_in_not_synced()
    -- Create master clip with video and audio at different in points
    local source_seq = Sequence.create("Unsynced", project_id,
        {fps_numerator = VIDEO_FPS_NUM, fps_denominator = VIDEO_FPS_DEN},
        1920, 1080, {kind = "master"})
    assert(source_seq:save())

    local video_track = Track.create_video("V1", source_seq.id)
    assert(video_track:save())

    local audio_track = Track.create_audio("A1", source_seq.id)
    assert(audio_track:save())

    local master_clip = Clip.create("Unsynced Master", nil, {
        project_id = project_id,
        clip_kind = "master",
        source_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(master_clip:save({skip_occlusion = true}))

    -- Video clip at frame 0
    local video_clip = Clip.create("Video", nil, {
        project_id = project_id,
        track_id = video_track.id,
        parent_clip_id = master_clip.id,
        owner_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_FRAMES,
        source_in = 0,
        source_out = DURATION_FRAMES,
        fps_numerator = VIDEO_FPS_NUM,
        fps_denominator = VIDEO_FPS_DEN,
    })
    assert(video_clip:save({skip_occlusion = true}))

    -- Audio clip at frame 48 (not synced!) - using sample equivalent of 48 frames
    local audio_clip = Clip.create("Audio", nil, {
        project_id = project_id,
        track_id = audio_track.id,
        parent_clip_id = master_clip.id,
        owner_sequence_id = source_seq.id,
        timeline_start = 0,
        duration = DURATION_SAMPLES,
        source_in = 96000,  -- 48 frames worth of samples (not 0 like video)
        source_out = DURATION_SAMPLES,
        fps_numerator = SAMPLE_RATE,
        fps_denominator = 1,
    })
    assert(audio_clip:save({skip_occlusion = true}))

    local loaded = Clip.load(master_clip.id)

    -- Should return nil because video source_in=0 but audio source_in=96000
    local synced_in = loaded:get_all_streams_in()
    assert(synced_in == nil, "get_all_streams_in should return nil when streams not synced")

    print("  ✓ get_all_streams_in returns nil when streams not synced")

    -- Cleanup
    db:exec("DELETE FROM clips WHERE id = '" .. audio_clip.id .. "'")
    db:exec("DELETE FROM clips WHERE id = '" .. video_clip.id .. "'")
    db:exec("DELETE FROM clips WHERE id = '" .. master_clip.id .. "'")
    db:exec("DELETE FROM tracks WHERE sequence_id = '" .. source_seq.id .. "'")
    db:exec("DELETE FROM sequences WHERE id = '" .. source_seq.id .. "'")
end

test_get_all_streams_in_not_synced()

print("\n✅ test_per_stream_master_clips_errors.lua passed")
