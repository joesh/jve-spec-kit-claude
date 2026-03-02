#!/usr/bin/env luajit

-- Test GoToStart and GoToEnd navigation commands
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Forward-declare mock_monitor (assigned after timeline_state loads)
local mock_monitor

-- Mock panel_manager — justified: seek_to_frame requires Qt engine
package.loaded['ui.panel_manager'] = {
    get_active_sequence_monitor = function() return mock_monitor end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_go_to_start_end.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 500, 150, '[]', '[]', '[]', 0, %d, %d);

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
    playhead = 150,
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

print("=== GoToStart / GoToEnd Tests ===")

-- Test 1: GoToStart moves playhead to frame 0
print("Test 1: GoToStart moves playhead to frame 0")
timeline_state.set_playhead_position(150)
local result = command_manager.execute("GoToStart", { project_id = "default_project" })
assert(result.success, "GoToStart should succeed: " .. tostring(result.error_message))
assert(timeline_state.get_playhead_position() == 0,
    string.format("GoToStart should move to frame 0, got %s", tostring(timeline_state.get_playhead_position())))

-- Test 2: GoToEnd moves playhead to total_frames of the active monitor
print("Test 2: GoToEnd moves playhead to total_frames")
mock_monitor.total_frames = 350
timeline_state.set_playhead_position(0)
result = command_manager.execute("GoToEnd", { project_id = "default_project" })
assert(result.success, "GoToEnd should succeed: " .. tostring(result.error_message))
assert(timeline_state.get_playhead_position() == 350,
    string.format("GoToEnd should move to frame 350, got %s", tostring(timeline_state.get_playhead_position())))

-- Test 3: GoToStart is idempotent (already at start)
print("Test 3: GoToStart is idempotent")
timeline_state.set_playhead_position(0)
result = command_manager.execute("GoToStart", { project_id = "default_project" })
assert(result.success, "GoToStart should succeed when already at start")
assert(timeline_state.get_playhead_position() == 0, "GoToStart should stay at 0")

-- Test 4: GoToEnd is idempotent (already at end)
print("Test 4: GoToEnd is idempotent")
timeline_state.set_playhead_position(350)
result = command_manager.execute("GoToEnd", { project_id = "default_project" })
assert(result.success, "GoToEnd should succeed when already at end")
assert(timeline_state.get_playhead_position() == 350, "GoToEnd should stay at 350")

-- Test 5: GoToEnd with zero total_frames goes to 0
print("Test 5: GoToEnd with zero total_frames")
mock_monitor.total_frames = 0
timeline_state.set_playhead_position(100)
result = command_manager.execute("GoToEnd", { project_id = "default_project" })
assert(result.success, "GoToEnd should succeed with zero total_frames")
assert(timeline_state.get_playhead_position() == 0,
    string.format("GoToEnd with zero total_frames should go to 0, got %s",
        tostring(timeline_state.get_playhead_position())))

-- Test 6: set_playhead_position receives integer, not Rational
print("Test 6: set_playhead_position receives integer, not Rational")
timeline_state.set_playhead_position(50)
result = command_manager.execute("GoToStart", { project_id = "default_project" })
assert(result.success, "GoToStart should succeed")
assert(type(timeline_state.get_playhead_position()) == "number",
    "playhead should be number, got " .. type(timeline_state.get_playhead_position()))

print("✅ test_go_to_start_end.lua passed")
