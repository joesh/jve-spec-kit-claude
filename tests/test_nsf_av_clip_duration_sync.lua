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
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('%s', 'Test Project', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], project_id, now, now))

-- Create timeline sequence at 30fps
local timeline = Sequence.create("Timeline", project_id, { fps_numerator = 30, fps_denominator = 1}, 1920, 1080,
    {kind = "sequence", audio_sample_rate = 48000 })
assert(timeline:save(), "Failed to save timeline")

local video_track = Track.create_video("V1", timeline.id, {index = 1})
assert(video_track:save(), "Failed to save video track")

local audio_track = Track.create_audio("A1", timeline.id, {index = 1})
assert(audio_track:save(), "Failed to save audio track")

-- V13: master sequences are created by Sequence.ensure_master from a Media
-- row. The internal V/A "streams" are media_refs (not clips). Test fixture
-- below uses the proper V13 path.
local dkjson = require("dkjson")
local media = Media.create({
    id = "av_dur_media",
    project_id = project_id,
    file_path = "/fake/test.mp4",
    name = "test.mp4",
    duration_frames = 240,  -- 10s at 24fps
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = 48000,
    metadata = dkjson.encode({
        start_tc_value = 0, start_tc_rate = 24,
        start_tc_audio_samples = 0, start_tc_audio_rate = 48000,
    }),
})
assert(media:save(), "Failed to save media")

local masterclip_id = Sequence.ensure_master("av_dur_media", project_id)
local masterclip = Sequence.load(masterclip_id)
assert(masterclip, "ensure_master returned no loadable sequence")
local video_duration_frames = 240
local audio_duration_samples = 480000  -- 10 * 48000

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

-- 018 (FR-016, FR-017): test_frame_to_samples and
-- test_add_clips_creates_synced_durations removed. They exercised the legacy
-- dual-unit accessors (Sequence:frame_to_samples,
-- clip_edit_helper.resolve_*_stream_timing) deleted in Phase 3.7. The same
-- "video and audio represent the same time" invariant is now covered by
-- test_timeline_clips_visual_sync below (timeline-level) and by
-- test_resolver_subframe (resolver-level, FR-008).

-- Test: Timeline clips have matching visual durations
local function test_timeline_clips_visual_sync()
    -- Execute Insert command
    local result = command_manager.execute("Insert", {
        project_id = project_id,
        sequence_id = timeline.id,
        target_video_track_id = video_track.id,
        source_sequence_id = masterclip.id,
        sequence_start_frame = 0,
    })
    assert(result and result.success, "Insert failed: " .. tostring(result and result.error_message))

    -- Query video clip from timeline
    local video_stmt = db:prepare([[
        SELECT duration_frames, sequence_start_frame
        FROM clips WHERE track_id = ? AND owner_sequence_id = ?
    ]])
    video_stmt:bind_value(1, video_track.id)
    video_stmt:bind_value(2, timeline.id)
    assert(video_stmt:exec(), "Video clip query failed")
    assert(video_stmt:next(), "No video clip created on timeline")
    local vc_duration = video_stmt:value(0)
    local vc_start = video_stmt:value(1)
    video_stmt:finalize()

    -- Query audio clip from timeline
    local audio_stmt = db:prepare([[
        SELECT duration_frames, sequence_start_frame
        FROM clips WHERE track_id = ? AND owner_sequence_id = ?
    ]])
    audio_stmt:bind_value(1, audio_track.id)
    audio_stmt:bind_value(2, timeline.id)
    assert(audio_stmt:exec(), "Audio clip query failed")
    assert(audio_stmt:next(), "No audio clip created on timeline")
    local ac_duration = audio_stmt:value(0)
    local ac_start = audio_stmt:value(1)
    audio_stmt:finalize()

    -- Both should have same sequence_start
    assert(vc_start == ac_start,
        string.format("sequence_start mismatch: video=%d, audio=%d", vc_start, ac_start))

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
test_timeline_clips_visual_sync()

print("✅ test_nsf_av_clip_duration_sync.lua passed")
