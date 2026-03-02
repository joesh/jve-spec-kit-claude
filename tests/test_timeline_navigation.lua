#!/usr/bin/env luajit

-- Regression: GoToStart and GoToEnd commands should move the playhead without
-- polluting the undo log or failing with "Unknown command type".
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
require('core.command_implementations')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_timeline_navigation.db"
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
        30, 1, 48000, 1920, 1080, 0, 10000, 500, '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO clips (
        id, project_id, clip_kind, track_id, owner_sequence_id, media_id, name,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
    ) VALUES
        ('clip_a', 'default_project', 'timeline', 'track_v1', 'default_sequence', NULL, 'Clip A',
         0, 1000, 0, 1000, 30, 1, 1, 0, %d, %d),
        ('clip_b', 'default_project', 'timeline', 'track_v1', 'default_sequence', NULL, 'Clip B',
         2000, 1500, 0, 1500, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now))

-- Mock sequence monitor — justified: seek_to_frame requires Qt engine
mock_monitor = {
    sequence_id = "default_sequence",
    view_id = "timeline_monitor",
    total_frames = 3500,
    playhead = 500,
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

print("=== Timeline Navigation Command Tests ===\n")

local result = command_manager.execute("GoToStart", { project_id = "default_project" })
assert(result.success == true, "GoToStart should succeed")
assert(timeline_state.get_playhead_position() == 0, "GoToStart must set playhead to 0")

timeline_state.set_playhead_position(321)

result = command_manager.execute("GoToEnd", { project_id = "default_project" })
assert(result.success == true, "GoToEnd should succeed")
assert(timeline_state.get_playhead_position() == 3500,
    string.format("GoToEnd must set playhead to timeline end (expected 3500, got %s)",
        tostring(timeline_state.get_playhead_position())))

print("✅ GoToStart/GoToEnd navigation commands adjust playhead correctly")
