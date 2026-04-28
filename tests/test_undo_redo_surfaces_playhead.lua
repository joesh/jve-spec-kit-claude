#!/usr/bin/env luajit

-- Regression test: Undo/Redo ceremony must surface the viewport when
-- the restored playhead is off-screen.
-- Bug: the ceremony called set_playhead_position() but never surface_playhead(),
-- so viewport didn't scroll to show the restored playhead.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local command_manager = require('core.command_manager')
local Command = require('command')
local database = require('core.database')
local timeline_state = require('ui.timeline.timeline_state')

print("=== Undo/Redo Viewport Surfacing Tests ===\n")

-- Setup test database
local test_db_path = "/tmp/jve/test_undo_redo_surfaces_playhead.db"
os.remove(test_db_path)
os.remove(test_db_path .. "-wal")
os.remove(test_db_path .. "-shm")

database.init(test_db_path)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj1', 'Test Project', 'resample', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'seq1', 'proj1', 'Test Sequence', 'nested',
        30, 1, 48000, 1920, 1080, 0, 500, 0,
        '[]', '[]', '[]', 0, %d, %d
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

command_manager.init('seq1', 'proj1')

-- Position playhead at frame 5000 (off the viewport [0,500))
-- then execute a command so undo captures playhead_value=5000
timeline_state.set_playhead_position(5000)

local cmd1 = Command.create("CreateSequence", "proj1")
cmd1:set_parameter("name", "Dummy Seq")
cmd1:set_parameter("project_id", "proj1")
cmd1:set_parameter("frame_rate", 30.0)
cmd1:set_parameter("width", 1920)
cmd1:set_parameter("height", 1080)
cmd1:set_parameter("audio_sample_rate", 48000)
local result = command_manager.execute(cmd1)
assert(result.success, "cmd1 should succeed: " .. tostring(result.error_message))

-- Move playhead to frame 100 (within viewport [0,500))
-- and scroll viewport to [0,500)
timeline_state.set_playhead_position(100)
timeline_state.set_viewport_start_time(0)

-- Test 1: Undo restores playhead and surfaces viewport
print("Test 1: Undo surfaces viewport when playhead off-screen")
result = command_manager.undo()
assert(result.success, "undo should succeed: " .. tostring(result.error_message))
assert(timeline_state.get_playhead_position() == 5000,
    string.format("playhead should be 5000 after undo, got %d",
        timeline_state.get_playhead_position()))
local vp_start = timeline_state.get_viewport_start_time()
local vp_end = vp_start + timeline_state.get_viewport_duration()
assert(vp_start <= 5000 and 5000 <= vp_end,
    string.format("viewport [%d, %d) should contain playhead 5000 after undo", vp_start, vp_end))

-- Test 2: Redo surfaces viewport
-- Move viewport far away from where redo will land
timeline_state.set_viewport_start_time(4500)
print("Test 2: Redo surfaces viewport when playhead off-screen")
result = command_manager.redo()
assert(result.success, "redo should succeed: " .. tostring(result.error_message))
local redo_playhead = timeline_state.get_playhead_position()
vp_start = timeline_state.get_viewport_start_time()
vp_end = vp_start + timeline_state.get_viewport_duration()
assert(vp_start <= redo_playhead and redo_playhead <= vp_end,
    string.format("viewport [%d, %d) should contain playhead %d after redo",
        vp_start, vp_end, redo_playhead))

print("✅ test_undo_redo_surfaces_playhead.lua passed")
