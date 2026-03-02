#!/usr/bin/env luajit

-- Test GoToNextEdit and GoToPrevEdit navigation commands
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Forward-declare mock_monitor
local mock_monitor

-- Mock panel_manager — justified: seek_to_frame requires Qt engine
package.loaded['ui.panel_manager'] = {
    get_active_sequence_monitor = function() return mock_monitor end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_go_to_next_prev_edit.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

-- Create clips: clip_a [0, 100), gap [100, 200), clip_b [200, 350)
-- Edit points: 0, 100, 200, 350
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 500, 50, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO clips (
        id, project_id, clip_kind, track_id, owner_sequence_id, media_id, name,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
    ) VALUES
        ('clip_a', 'default_project', 'timeline', 'track_v1', 'default_sequence', NULL, 'Clip A',
         0, 100, 0, 100, 30, 1, 1, 0, %d, %d),
        ('clip_b', 'default_project', 'timeline', 'track_v1', 'default_sequence', NULL, 'Clip B',
         200, 150, 0, 150, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now))

-- Mock sequence monitor — justified: seek_to_frame requires Qt engine
mock_monitor = {
    sequence_id = "default_sequence",
    view_id = "timeline_monitor",
    total_frames = 350,
    playhead = 50,
    engine = {
        is_playing = function() return false end,
        stop = function() end,
    },
}
function mock_monitor:seek_to_frame(frame)
    self.playhead = math.max(0, math.floor(frame))
    timeline_state.set_playhead_position(self.playhead)
end

command_manager.init('default_sequence', 'default_project')

print("=== GoToNextEdit / GoToPrevEdit Tests ===")

-- Test 1: GoToNextEdit from middle of clip_a moves to end of clip_a (frame 100)
print("Test 1: GoToNextEdit from middle of clip_a")
timeline_state.set_playhead_position(50)
local result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed: " .. tostring(result.error_message))
assert(timeline_state.get_playhead_position() == 100,
    string.format("GoToNextEdit should move to frame 100, got %d", timeline_state.get_playhead_position()))

-- Test 2: GoToNextEdit from frame 100 (end of clip_a) moves to frame 200 (start of clip_b)
print("Test 2: GoToNextEdit from end of clip_a")
timeline_state.set_playhead_position(100)
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed")
assert(timeline_state.get_playhead_position() == 200,
    string.format("GoToNextEdit should move to frame 200, got %d", timeline_state.get_playhead_position()))

-- Test 3: GoToNextEdit from frame 200 moves to frame 350 (end of clip_b)
print("Test 3: GoToNextEdit from start of clip_b")
timeline_state.set_playhead_position(200)
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed")
assert(timeline_state.get_playhead_position() == 350,
    string.format("GoToNextEdit should move to frame 350, got %d", timeline_state.get_playhead_position()))

-- Test 4: GoToNextEdit at end of timeline stays at end
print("Test 4: GoToNextEdit at end of timeline")
timeline_state.set_playhead_position(350)
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed at end")
assert(timeline_state.get_playhead_position() == 350,
    string.format("GoToNextEdit should stay at frame 350, got %d", timeline_state.get_playhead_position()))

-- Test 5: GoToPrevEdit from middle of clip_b moves to frame 200
print("Test 5: GoToPrevEdit from middle of clip_b")
timeline_state.set_playhead_position(300)
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed: " .. tostring(result.error_message))
assert(timeline_state.get_playhead_position() == 200,
    string.format("GoToPrevEdit should move to frame 200, got %d", timeline_state.get_playhead_position()))

-- Test 6: GoToPrevEdit from frame 200 moves to frame 100
print("Test 6: GoToPrevEdit from start of clip_b")
timeline_state.set_playhead_position(200)
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed")
assert(timeline_state.get_playhead_position() == 100,
    string.format("GoToPrevEdit should move to frame 100, got %d", timeline_state.get_playhead_position()))

-- Test 7: GoToPrevEdit from frame 100 moves to frame 0
print("Test 7: GoToPrevEdit from end of clip_a")
timeline_state.set_playhead_position(100)
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed")
assert(timeline_state.get_playhead_position() == 0,
    string.format("GoToPrevEdit should move to frame 0, got %d", timeline_state.get_playhead_position()))

-- Test 8: GoToPrevEdit at start of timeline stays at start
print("Test 8: GoToPrevEdit at start of timeline")
timeline_state.set_playhead_position(0)
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed at start")
assert(timeline_state.get_playhead_position() == 0,
    string.format("GoToPrevEdit should stay at frame 0, got %d", timeline_state.get_playhead_position()))

-- Test 9: Navigation in gap (between clips) still finds correct edit points
print("Test 9: GoToNextEdit from gap")
timeline_state.set_playhead_position(150)
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success, "GoToNextEdit should succeed from gap")
assert(timeline_state.get_playhead_position() == 200,
    string.format("GoToNextEdit from gap should move to frame 200, got %d", timeline_state.get_playhead_position()))

-- Test 10: GoToPrevEdit from gap
print("Test 10: GoToPrevEdit from gap")
timeline_state.set_playhead_position(150)
result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success, "GoToPrevEdit should succeed from gap")
assert(timeline_state.get_playhead_position() == 100,
    string.format("GoToPrevEdit from gap should move to frame 100, got %d", timeline_state.get_playhead_position()))

-- Test 11: Round-trip navigation
print("Test 11: Next/Prev round-trip")
timeline_state.set_playhead_position(50)
command_manager.execute("GoToNextEdit", { project_id = "default_project" })  -- -> 100
command_manager.execute("GoToPrevEdit", { project_id = "default_project" })  -- -> 0 (not 50, goes to previous edit)
assert(timeline_state.get_playhead_position() == 0,
    string.format("Round-trip should end at frame 0, got %d", timeline_state.get_playhead_position()))

print("✅ GoToNextEdit/GoToPrevEdit tests passed")
