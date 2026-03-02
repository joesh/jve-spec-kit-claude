#!/usr/bin/env luajit

-- Regression: GoToPrevEdit / GoToNextEdit should move the playhead to the
-- nearest clip boundary without creating undo entries.
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Forward-declare mock_monitor for closure capture
local mock_monitor

-- Mock panel_manager — justified: GoToPrevEdit/GoToNextEdit require
-- sv.sequence_id and sv.engine (Qt engine) from the active monitor.
-- Playhead is set directly via timeline_state, not via seek_to_frame.
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return mock_monitor end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
require('core.command_implementations')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_timeline_edit_navigation.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

-- Timeline layout (in frames):
-- V1: clip_a [0, 1500), clip_b [3000, 4500)
-- V2: clip_c [1200, 2400), clip_d [5000, 6200)
-- Edit points: 0, 1200, 1500, 2400, 3000, 4500, 5000, 6200
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 10000, 2500,
        '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_clip_a', 'default_project', 'clip_a.mov', '/tmp/jve/clip_a.mov', 1500, 30, 1,
        1920, 1080, 0, '', '{}', %d, %d);
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_clip_b', 'default_project', 'clip_b.mov', '/tmp/jve/clip_b.mov', 1500, 30, 1,
        1920, 1080, 0, '', '{}', %d, %d);
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_clip_c', 'default_project', 'clip_c.mov', '/tmp/jve/clip_c.mov', 1200, 30, 1,
        1920, 1080, 0, '', '{}', %d, %d);
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_clip_d', 'default_project', 'clip_d.mov', '/tmp/jve/clip_d.mov', 1200, 30, 1,
        1920, 1080, 0, '', '{}', %d, %d);

    INSERT INTO clips (id, project_id, clip_kind, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_a', 'default_project', 'timeline', 'track_v1', 'media_clip_a', 'default_sequence',
        0, 1500, 0, 1500, 30, 1, 1, 0, %d, %d);
    INSERT INTO clips (id, project_id, clip_kind, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_b', 'default_project', 'timeline', 'track_v1', 'media_clip_b', 'default_sequence',
        3000, 1500, 0, 1500, 30, 1, 1, 0, %d, %d);
    INSERT INTO clips (id, project_id, clip_kind, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_c', 'default_project', 'timeline', 'track_v2', 'media_clip_c', 'default_sequence',
        1200, 1200, 0, 1200, 30, 1, 1, 0, %d, %d);
    INSERT INTO clips (id, project_id, clip_kind, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_d', 'default_project', 'timeline', 'track_v2', 'media_clip_d', 'default_sequence',
        5000, 1200, 0, 1200, 30, 1, 1, 0, %d, %d);
]], now, now, now, now,
   now, now, now, now, now, now, now, now,
   now, now, now, now, now, now, now, now))

-- Mock sequence monitor — justified: engine.is_playing/stop require Qt
mock_monitor = {
    sequence_id = "default_sequence",
    view_id = "timeline_monitor",
    engine = {
        is_playing = function() return false end,
        stop = function() end,
    },
}

command_manager.init('default_sequence', 'default_project')

print("=== Timeline Edit Navigation Tests ===\n")

-- Playhead starts at 2500 (set in sequences row)
assert(timeline_state.get_playhead_position() == 2500,
    string.format("Initial playhead expected 2500, got %s",
        tostring(timeline_state.get_playhead_position())))

-- GoToPrevEdit from 2500 → 2400 (end of clip_c on V2)
local result = command_manager.execute("GoToPrevEdit", { project_id = "default_project" })
assert(result.success == true, "GoToPrevEdit should succeed")
assert(timeline_state.get_playhead_position() == 2400,
    string.format("GoToPrevEdit expected 2400, got %s",
        tostring(timeline_state.get_playhead_position())))

-- Set playhead to 3200, GoToNextEdit → 4500 (end of clip_b on V1)
timeline_state.set_playhead_position(3200)
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success == true, "GoToNextEdit should succeed")
assert(timeline_state.get_playhead_position() == 4500,
    string.format("GoToNextEdit expected 4500, got %s",
        tostring(timeline_state.get_playhead_position())))

-- At timeline end (6200), GoToNextEdit should stay put
timeline_state.set_playhead_position(6200)
result = command_manager.execute("GoToNextEdit", { project_id = "default_project" })
assert(result.success == true, "GoToNextEdit should succeed even at timeline end")
assert(timeline_state.get_playhead_position() == 6200,
    string.format("GoToNextEdit at end should stay at 6200, got %s",
        tostring(timeline_state.get_playhead_position())))

print("✅ GoToPrevEdit/GoToNextEdit navigation commands adjust playhead correctly")
