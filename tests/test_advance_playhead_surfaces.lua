#!/usr/bin/env luajit

-- Regression test: Insert/Overwrite advance_playhead must emit playhead_changed
-- signal and persist to DB, not just update in-memory viewport state.
-- Bug: add_clips_to_sequence called timeline_state.set_playhead_position() directly,
-- bypassing model persistence and signal emission.

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
local Signals = require("core.signals")
local Sequence = require("models.sequence")

print("=== AddClipsToSequence advance_playhead Surfacing Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_advance_playhead_surfaces.jvp"
os.remove(db_path)
os.remove(db_path .. "-wal")
os.remove(db_path .. "-shm")
database.init(db_path)
local db = database.get_connection()

-- Disable overlap triggers for cleaner testing
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

local Project = require("models.project")
local Track = require("models.track")

local project = Project.create("Test Project", { fps_mismatch_policy = 'resample' })
project:save()

local seq = Sequence.create("Test Sequence", project.id,
    {  fps_numerator = 30, fps_denominator = 1 }, 1920, 1080,
    { kind = "nested", audio_rate = 48000 })
seq:save()

Track.create_video("V1", seq.id, { index = 1 }):save()
Track.create_audio("A1", seq.id, { index = 1 }):save()

-- Create media (200 frames @ 30fps)
local media = Media.create({
    id = "media_video",
    project_id = project.id,
    file_path = "/tmp/jve/video.mov",
    name = "Video",
    duration_frames = 200,
    fps_numerator = 30,
    fps_denominator = 1,
})
media:save(db)

-- Create masterclip sequence
local nested_sequence_id = test_env.create_test_masterclip_sequence(
    project.id, "Video Master", 30, 1, 200, "media_video")

-- Init command system + real timeline_state
command_manager.init(seq.id, project.id)

-- Place playhead at frame 100
timeline_state.set_playhead_position(100)

-- Track signal emissions
local signal_log = {}
Signals.connect("playhead_changed", function(sequence_id, frame)
    table.insert(signal_log, { sequence_id = sequence_id, frame = frame })
end)

-- Resolve track_id
local tracks = Track.find_by_sequence(seq.id)
local video_track_id
for _, t in ipairs(tracks) do
    if t.track_type == "VIDEO" then video_track_id = t.id; break end
end
assert(video_track_id, "Should have a video track")

-- Test 1: Insert with advance_playhead emits playhead_changed signal
print("Test 1: Insert with advance_playhead emits playhead_changed")
signal_log = {}
local result = command_manager.execute("Insert", {
    project_id = project.id,
    sequence_id = seq.id,
    nested_sequence_id = master_clip_id,
    advance_playhead = true,
})
assert(result.success, "Insert should succeed: " .. tostring(result.error_message))

-- Playhead should have advanced by clip duration (200 frames from position 100 = 300)
local expected_playhead = 100 + 200
assert(timeline_state.get_playhead_position() == expected_playhead,
    string.format("playhead should be at %d, got %d", expected_playhead,
        timeline_state.get_playhead_position()))

-- Signal must have been emitted
assert(#signal_log > 0,
    "advance_playhead must emit playhead_changed signal (got 0 emissions)")
local last_signal = signal_log[#signal_log]
assert(last_signal.frame == expected_playhead,
    string.format("signal should carry frame %d, got %s",
        expected_playhead, tostring(last_signal.frame)))

-- Test 2: Playhead persisted to DB
print("Test 2: advance_playhead persists to DB")
local reloaded = Sequence.load(seq.id)
assert(reloaded, "sequence should be loadable")
assert(reloaded.playhead_position == expected_playhead,
    string.format("DB playhead should be %d, got %s",
        expected_playhead, tostring(reloaded.playhead_position)))

print("✅ test_advance_playhead_surfaces.lua passed")
