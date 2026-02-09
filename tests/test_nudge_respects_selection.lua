-- Regression test: Nudge should only move selected clips, not linked clips
-- Link is a selection hint, not a command behavior
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local ClipLink = require("models.clip_link")
local Clip = require("models.clip")

local db_path = "/tmp/jve/test_nudge_respects_selection.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- Setup: project, sequence, tracks, media
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_v', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a', 'seq1', 'A1', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'media.mov', '/tmp/media.mov', 1000,
        24000, 1001, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now, now, now, now, now))

-- Create video clip at frame 0, duration 100
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_v', 'proj1', 'timeline', 'Video Clip', 'trk_v', 'med1',
        0, 100, 0, 100, 24000, 1001, 1, 0, %d, %d);
]], now, now))

-- Create audio clip at frame 0, duration 100
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_a', 'proj1', 'timeline', 'Audio Clip', 'trk_a', 'med1',
        0, 100, 0, 100, 24000, 1001, 1, 0, %d, %d);
]], now, now))

-- Link the clips
ClipLink.create_link_group({
    { clip_id = "clip_v", role = "video", time_offset = 0 },
    { clip_id = "clip_a", role = "audio", time_offset = 0 },
}, db)

-- Verify linked
assert(ClipLink.is_linked("clip_v", db), "clip_v should be linked")
assert(ClipLink.is_linked("clip_a", db), "clip_a should be linked")

-- Initialize command manager
command_manager.init("seq1", "proj1")

-- Record original positions
local video_before = Clip.load("clip_v")
local audio_before = Clip.load("clip_a")
assert(video_before.timeline_start == 0, "video should start at 0")
assert(audio_before.timeline_start == 0, "audio should start at 0")

-- Nudge ONLY the video clip by 10 frames
local result = command_manager.execute("Nudge", {
    project_id = "proj1",
    sequence_id = "seq1",
    fps_numerator = 24000,
    fps_denominator = 1001,
    nudge_amount = 10,
    selected_clip_ids = { "clip_v" },  -- ONLY video selected
})
assert(result.success, "Nudge should succeed: " .. (result.error_message or ""))

-- Reload clips
local video_after = Clip.load("clip_v")
local audio_after = Clip.load("clip_a")

-- Video should have moved
assert(video_after.timeline_start == 10,
    string.format("video should be at frame 10, got %d", video_after.timeline_start))

-- Audio should NOT have moved (it was not selected)
assert(audio_after.timeline_start == 0,
    string.format("audio should still be at frame 0 (not selected), got %d", audio_after.timeline_start))

print("✅ test_nudge_respects_selection.lua passed")
