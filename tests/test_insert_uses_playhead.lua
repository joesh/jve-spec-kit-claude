#!/usr/bin/env luajit

-- Regression test: Insert command should use playhead position when insert_time not specified.
-- Bug: insert_time had default=0 in SPEC, so it was never nil, and playhead was never consulted.
--
-- Uses REAL timeline_state (not mocked) — exercises the actual playhead state management.

local test_env = require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local Media = require('models.media')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

print("=== Insert Uses Playhead Position Test ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_insert_uses_playhead.jvp"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
database.init(db_path)
local db = database.get_connection()

-- Disable overlap triggers for cleaner testing
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

-- Insert Project/Sequence (30fps)
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")

local project = Project.create("Test Project")
project:save()

local seq = Sequence.create("Test Sequence", project.id,
    { fps_numerator = 30, fps_denominator = 1 }, 1920, 1080)
seq:save()

Track.create_video("V1", seq.id, { index = 1 }):save()
Track.create_audio("A1", seq.id, { index = 1 }):save()

-- Create Media (100 frames @ 30fps)
local media = Media.create({
    id = "media_video",
    project_id = project.id,
    file_path = "/tmp/jve/video.mov",
    name = "Video",
    duration_frames = 100,
    fps_numerator = 30,
    fps_denominator = 1,
})
media:save(db)

-- Create masterclip sequence for this media (required for Insert)
local master_clip_id = test_env.create_test_masterclip_sequence(
    project.id, "Video Master", 30, 1, 100, "media_video")

-- Init command system + real timeline_state
command_manager.init(seq.id, project.id)

-- Set playhead to frame 150 using the REAL timeline_state
timeline_state.set_playhead_position(150)
assert(timeline_state.get_playhead_position() == 150,
    "Playhead should be at 150, got " .. tostring(timeline_state.get_playhead_position()))

-- Resolve track_id from DB
local tracks = Track.find_by_sequence(seq.id)
local video_track_id
for _, t in ipairs(tracks) do
    if t.track_type == "VIDEO" then video_track_id = t.id; break end
end
assert(video_track_id, "Should have a VIDEO track")

-- =============================================================================
-- TEST: Insert without insert_time should use playhead position (frame 150)
-- =============================================================================
print("Test: Insert without insert_time uses playhead position")

command_manager.begin_command_event("script")
local result = command_manager.execute("Insert", {
    master_clip_id = master_clip_id,
    track_id = video_track_id,
    sequence_id = seq.id,
    project_id = project.id,
    duration = 50,
    source_in = 0,
    source_out = 50,
})
command_manager.end_command_event()
assert(result.success, "Insert should succeed: " .. tostring(result.error_message))

-- Verify clip was inserted at playhead position (150), NOT at 0
local all_clips = database.load_clips(seq.id)
local timeline_clips = {}
for _, c in ipairs(all_clips) do
    if c.track_id == video_track_id then
        timeline_clips[#timeline_clips + 1] = c
    end
end

assert(#timeline_clips == 1, string.format("Expected 1 clip, got %d", #timeline_clips))
assert(timeline_clips[1].timeline_start == 150,
    string.format("Clip should start at 150, got %s", tostring(timeline_clips[1].timeline_start)))
assert(timeline_clips[1].duration == 50,
    string.format("Clip should have duration 50, got %s", tostring(timeline_clips[1].duration)))

print("  ✓ Clip correctly inserted at playhead position (frame 150)")

print("\n✅ test_insert_uses_playhead.lua passed")
