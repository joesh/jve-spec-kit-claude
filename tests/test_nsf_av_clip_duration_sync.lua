--[[
NSF Test: Audio/Video Clip Duration Sync

When adding a clip to timeline, video and audio clips must have synchronized
durations (in their respective units). Audio duration in samples should
correspond to video duration in frames.

Bug: Audio clip on timeline was WAY longer than video clip visually.
]]

require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")
local Media = require("models.media")
local command_manager = require("core.command_manager")
require("uuid") -- luacheck: ignore 411

local db_path = "/tmp/jve/test_av_duration_sync.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

local project_id = "test_project"
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('%s', 'Test Project', %d, %d)
]], project_id, now, now))

-- Create timeline sequence at 30fps
local timeline = Sequence.create("Timeline", project_id, {fps_numerator = 30, fps_denominator = 1}, 1920, 1080)
assert(timeline:save(), "Failed to save timeline")

local video_track = Track.create_video("V1", timeline.id, {index = 1})
assert(video_track:save(), "Failed to save video track")

local audio_track = Track.create_audio("A1", timeline.id, {index = 1})
assert(audio_track:save(), "Failed to save audio track")

-- Create masterclip sequence at 24fps (simulating imported media)
local masterclip = Sequence.create("TestClip", project_id,
    {fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    {kind = "masterclip", audio_rate = 48000})
assert(masterclip:save(), "Failed to save masterclip")

-- Create video track in masterclip
local mc_video_track = Track.create_video("Video", masterclip.id, {index = 1})
assert(mc_video_track:save(), "Failed to save mc video track")

-- Create audio track in masterclip
local mc_audio_track = Track.create_audio("Audio", masterclip.id, {index = 1})
assert(mc_audio_track:save(), "Failed to save mc audio track")

-- Create media record
local media = Media.create({
    project_id = project_id,
    file_path = "/fake/test.mp4",
    name = "test.mp4",
    duration_frames = 240,  -- 10 seconds at 24fps
    fps_numerator = 24,
    fps_denominator = 1,
    audio_channels = 2,
})
assert(media:save(), "Failed to save media")

-- Create stream clips in masterclip
-- Video: 240 frames at 24fps = 10 seconds
-- Audio: 10 seconds * 48000 = 480000 samples
local video_duration_frames = 240
local audio_duration_samples = 480000  -- 10 * 48000

local video_stream = Clip.create("Video Stream", media.id, {
    project_id = project_id,
    track_id = mc_video_track.id,
    owner_sequence_id = masterclip.id,
    timeline_start = 0,
    duration = video_duration_frames,
    source_in = 0,
    source_out = video_duration_frames,
    fps_numerator = 24,
    fps_denominator = 1,
})
assert(video_stream:save({skip_occlusion = true}), "Failed to save video stream")

local audio_stream = Clip.create("Audio Stream", media.id, {
    project_id = project_id,
    track_id = mc_audio_track.id,
    owner_sequence_id = masterclip.id,
    timeline_start = 0,
    duration = audio_duration_samples,
    source_in = 0,
    source_out = audio_duration_samples,
    fps_numerator = 48000,
    fps_denominator = 1,
})
assert(audio_stream:save({skip_occlusion = true}), "Failed to save audio stream")

-- Initialize command manager
command_manager.init(timeline.id, project_id)

print("test_nsf_av_clip_duration_sync.lua")

-- Test: Stream clips have correct durations
local function test_stream_clip_durations()
    local reloaded_mc = Sequence.load(masterclip.id)
    local vs = reloaded_mc:video_stream()
    local audio_streams = reloaded_mc:audio_streams()

    assert(vs, "Video stream not found")
    assert(#audio_streams > 0, "Audio streams not found")

    local as = audio_streams[1]

    -- Video: 240 frames
    assert(vs.source_out - vs.source_in == video_duration_frames,
        string.format("Video stream duration mismatch: expected %d, got %d",
            video_duration_frames, vs.source_out - vs.source_in))

    -- Audio: 480000 samples
    assert(as.source_out - as.source_in == audio_duration_samples,
        string.format("Audio stream duration mismatch: expected %d, got %d",
            audio_duration_samples, as.source_out - as.source_in))

    -- Verify they represent the same TIME
    local video_seconds = video_duration_frames / 24
    local audio_seconds = audio_duration_samples / 48000
    assert(math.abs(video_seconds - audio_seconds) < 0.001,
        string.format("Duration time mismatch: video=%.3fs, audio=%.3fs",
            video_seconds, audio_seconds))

    print("  ✓ Stream clips have correct durations")
end

-- Test: frame_to_samples conversion
local function test_frame_to_samples()
    local reloaded_mc = Sequence.load(masterclip.id)

    -- 240 frames at 24fps -> samples at 48000
    -- samples = frames * sample_rate / fps = 240 * 48000 / 24 = 480000
    local expected_samples = 480000
    local actual_samples = reloaded_mc:frame_to_samples(video_duration_frames)

    assert(actual_samples == expected_samples,
        string.format("frame_to_samples mismatch: expected %d, got %d",
            expected_samples, actual_samples or -1))

    print("  ✓ frame_to_samples conversion correct")
end

-- Test: AddClipsToSequence creates synced A/V clips
local function test_add_clips_creates_synced_durations()
    local clip_edit_helper = require("core.clip_edit_helper")

    local reloaded_mc = Sequence.load(masterclip.id)

    -- Resolve timing (no overrides = use full stream duration)
    local video_timing = clip_edit_helper.resolve_video_stream_timing(reloaded_mc, {})
    local audio_timing = clip_edit_helper.resolve_audio_stream_timing(reloaded_mc, {})

    assert(video_timing, "Failed to resolve video timing")
    assert(audio_timing, "Failed to resolve audio timing")

    -- Video duration in frames
    assert(video_timing.duration == video_duration_frames,
        string.format("Video timing duration mismatch: expected %d, got %d",
            video_duration_frames, video_timing.duration))

    -- Audio duration in samples
    assert(audio_timing.duration == audio_duration_samples,
        string.format("Audio timing duration mismatch: expected %d, got %d",
            audio_duration_samples, audio_timing.duration))

    -- They must represent the same time
    local video_fps = video_timing.fps_numerator / video_timing.fps_denominator
    local audio_fps = audio_timing.fps_numerator / audio_timing.fps_denominator  -- sample rate

    local video_seconds = video_timing.duration / video_fps
    local audio_seconds = audio_timing.duration / audio_fps

    assert(math.abs(video_seconds - audio_seconds) < 0.001,
        string.format("Timing duration time mismatch: video=%.3fs, audio=%.3fs",
            video_seconds, audio_seconds))

    print("  ✓ resolve_*_stream_timing returns synced durations")
end

-- Test: Timeline clips have matching visual durations
local function test_timeline_clips_visual_sync()
    -- Execute Insert command
    local result = command_manager.execute("Insert", {
        project_id = project_id,
        sequence_id = timeline.id,
        track_id = video_track.id,
        master_clip_id = masterclip.id,
        insert_time = 0,
    })
    assert(result and result.success, "Insert failed: " .. tostring(result and result.error_message))

    -- Query video clip from timeline
    local video_stmt = db:prepare([[
        SELECT duration_frames, fps_numerator, fps_denominator, timeline_start_frame
        FROM clips WHERE track_id = ? AND owner_sequence_id = ?
    ]])
    video_stmt:bind_value(1, video_track.id)
    video_stmt:bind_value(2, timeline.id)
    assert(video_stmt:exec(), "Video clip query failed")
    assert(video_stmt:next(), "No video clip created on timeline")
    local vc_duration = video_stmt:value(0)
    local _ = video_stmt:value(1) -- fps_num (unused)
    local _ = video_stmt:value(2) -- fps_den (unused)  -- luacheck: ignore 411
    local vc_start = video_stmt:value(3)
    video_stmt:finalize()

    -- Query audio clip from timeline
    local audio_stmt = db:prepare([[
        SELECT duration_frames, fps_numerator, fps_denominator, timeline_start_frame
        FROM clips WHERE track_id = ? AND owner_sequence_id = ?
    ]])
    audio_stmt:bind_value(1, audio_track.id)
    audio_stmt:bind_value(2, timeline.id)
    assert(audio_stmt:exec(), "Audio clip query failed")
    assert(audio_stmt:next(), "No audio clip created on timeline")
    local ac_duration = audio_stmt:value(0)
    local _ = audio_stmt:value(1) -- fps_num (unused)
    local _ = audio_stmt:value(2) -- fps_den (unused)  -- luacheck: ignore 411
    local ac_start = audio_stmt:value(3)
    audio_stmt:finalize()

    -- Both should have same timeline_start
    assert(vc_start == ac_start,
        string.format("timeline_start mismatch: video=%d, audio=%d", vc_start, ac_start))

    -- clip.duration is now in TIMELINE frames (30fps), not source units
    -- Both video and audio should have the same timeline duration
    assert(vc_duration == ac_duration,
        string.format("Timeline duration mismatch: video=%d, audio=%d (should be equal)",
            vc_duration, ac_duration))

    -- Calculate time in seconds using TIMELINE rate (30fps)
    local timeline_fps = 30
    local video_seconds = vc_duration / timeline_fps
    local audio_seconds = ac_duration / timeline_fps

    -- They must match (same duration value = same time)
    assert(video_seconds == audio_seconds,
        string.format("Timeline time mismatch: video=%.3fs, audio=%.3fs",
            video_seconds, audio_seconds))

    print("  ✓ Timeline clips have matching visual durations")
end

test_stream_clip_durations()
test_frame_to_samples()
test_add_clips_creates_synced_durations()
test_timeline_clips_visual_sync()

print("✅ test_nsf_av_clip_duration_sync.lua passed")
