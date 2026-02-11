-- Test: NSF compliance for gather_context_for_command.lua
-- Verifies that clip_media asserts are NOT swallowed by pcall
require("test_env")

local gather_context = require("core.gather_context_for_command")
local database = require("core.database")
local command_manager = require("core.command_manager")
local uuid = require("uuid")
local Media = require("models.media")
local Clip = require("models.clip")
local Track = require("models.track")
local Sequence = require("models.sequence")
local Project = require("models.project")

local function setup_test_db()
    local db_path = "/tmp/jve/test_nsf_gather_" .. uuid.generate() .. ".db"
    database.init(db_path)
    return database.get_connection()
end

local function create_test_project(db)
    local project_id = uuid.generate()
    local project = Project.create("Test Project", {id = project_id})
    project:save()
    return project_id
end

local function create_test_sequence(db, project_id)
    local seq = Sequence.create("Test Sequence", project_id, {fps_numerator = 24, fps_denominator = 1}, 1920, 1080)
    seq:save(db)

    local track = Track.create_video("V1", seq.id, {index = 1})
    track:save(db)

    return seq.id, track.id
end

-- Test: gather_edit_context asserts when master clip missing width/height (video check fails)
local function test_gather_context_asserts_on_missing_video_dimensions()
    local db = setup_test_db()
    local project_id = create_test_project(db)
    local sequence_id, track_id = create_test_sequence(db, project_id)

    command_manager.init(sequence_id, project_id)

    -- Create media with valid fps but MISSING width/height (0 = unknown)
    local media = Media.create({
        id = uuid.generate(),
        project_id = project_id,
        name = "Test Media",
        file_path = "/test/video.mp4",
        duration_frames = 240,
        fps_numerator = 24,
        fps_denominator = 1,
        width = 0,  -- Missing width
        height = 0, -- Missing height
        audio_channels = 0, -- No audio either
    })
    media:save()

    -- Create master clip referencing this media (also no dimensions)
    local master_clip = Clip.create("Test Clip", media.id, {
        id = uuid.generate(),
        project_id = project_id,
        clip_kind = "master",
        timeline_start = 0,
        duration = 240,
        source_in = 0,
        source_out = 240,
        fps_numerator = 24,
        fps_denominator = 1,
    })
    master_clip:save(db)

    -- Mock timeline_state
    local mock_timeline_state = {
        get_sequence_id = function() return sequence_id end,
        get_project_id = function() return project_id end,
        get_playhead_position = function() return 0 end,
    }

    -- Gather context should assert (not silently proceed with no video and no audio)
    local success, err = pcall(function()
        gather_context.gather_edit_context({
            master_clips = {master_clip},
            timeline_state = mock_timeline_state,
        })
    end)

    database.shutdown()

    -- Should fail with assertion about missing video/audio, not silently return empty clips
    assert(not success, "gather_edit_context should assert when clip has neither video nor audio dimensions")
    -- The error should mention the problem
    assert(err:match("video") or err:match("audio") or err:match("neither"),
        "Error should mention video/audio issue: " .. tostring(err))

    print("✓ test_gather_context_asserts_on_missing_video_dimensions passed")
end

-- Test: clip_media functions assert when passed nil values directly
-- This tests that pcall is not hiding clip_media asserts
local function test_clip_media_asserts_propagate()
    local clip_media = require("core.utils.clip_media")

    -- Test that has_video asserts on nil width/height
    local corrupt_clip = {width = nil, height = nil}
    local corrupt_media = {width = nil, height = nil}

    local success, err = pcall(function()
        return clip_media.has_video(corrupt_clip, corrupt_media)
    end)

    assert(not success, "clip_media.has_video should assert when width/height are nil")
    assert(err:match("video") or err:match("width"), "Error should mention video/width: " .. tostring(err))
    print("✓ clip_media.has_video correctly asserts on nil dimensions")

    -- Test that audio_channel_count asserts on nil channels
    local audio_corrupt_clip = {audio_channels = nil}
    local audio_corrupt_media = {audio_channels = nil}

    local audio_success, audio_err = pcall(function()
        return clip_media.audio_channel_count(audio_corrupt_clip, audio_corrupt_media)
    end)

    assert(not audio_success, "clip_media.audio_channel_count should assert when audio_channels is nil")
    assert(audio_err:match("audio"), "Error should mention audio: " .. tostring(audio_err))
    print("✓ clip_media.audio_channel_count correctly asserts on nil channels")

    print("✓ test_clip_media_asserts_propagate passed")
end

-- Test: gather_context uses clip_media without pcall (asserts propagate)
-- NOTE: Media.load uses intentional `or 0` fallbacks for NULL database values
-- (width=0 means "unknown/audio-only", audio_channels=0 means "unknown/video-only")
-- So we test with valid data that results in 0 = no audio clips is correct behavior
local function test_gather_context_valid_video_only_media()
    local db = setup_test_db()
    local project_id = create_test_project(db)
    local sequence_id, track_id = create_test_sequence(db, project_id)

    command_manager.init(sequence_id, project_id)

    -- Create video-only media (audio_channels = 0, which is valid)
    local media = Media.create({
        id = uuid.generate(),
        project_id = project_id,
        name = "Video Only",
        file_path = "/test/video.mp4",
        duration_frames = 240,
        fps_numerator = 24,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
        audio_channels = 0,  -- Explicitly video-only
    })
    media:save()

    -- Create master clip
    local master_clip = Clip.create("Video Only Clip", media.id, {
        id = uuid.generate(),
        project_id = project_id,
        clip_kind = "master",
        timeline_start = 0,
        duration = 240,
        source_in = 0,
        source_out = 240,
        fps_numerator = 24,
        fps_denominator = 1,
    })
    master_clip:save(db)

    -- Load tracks from DB
    local video_tracks = Track.find_by_sequence(sequence_id, "VIDEO")

    -- Mock timeline_state
    local mock_timeline_state = {
        get_sequence_id = function() return sequence_id end,
        get_project_id = function() return project_id end,
        get_playhead_position = function() return 0 end,
        get_video_tracks = function() return video_tracks end,
        get_audio_tracks = function() return {} end,  -- No audio tracks needed
    }

    -- Should succeed and create only video clip
    local result = gather_context.gather_edit_context({
        master_clips = {master_clip},
        timeline_state = mock_timeline_state,
    })

    database.shutdown()

    assert(result.groups and #result.groups == 1, "Should have 1 group")
    assert(result.groups[1].clips and #result.groups[1].clips == 1, "Should have 1 clip (video only)")
    assert(result.groups[1].clips[1].role == "video", "Clip should be video role")

    print("✓ test_gather_context_valid_video_only_media passed")
end

-- Run tests
test_gather_context_asserts_on_missing_video_dimensions()
test_clip_media_asserts_propagate()
test_gather_context_valid_video_only_media()

print("✅ test_nsf_gather_context.lua passed")
