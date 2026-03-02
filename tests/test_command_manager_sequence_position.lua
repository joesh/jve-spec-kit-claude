#!/usr/bin/env luajit

-- Test that command_manager correctly tracks per-sequence undo positions
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/jve/test_command_manager_sequence_position.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

assert(db:exec(require('import_schema')))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now, now, now)))

command_manager.init("default_sequence", "default_project")

assert(not command_manager.can_undo(), "Default sequence should start at fully-undone position")

command_manager.activate_timeline_stack("sequence_b")
assert(not command_manager.can_undo(), "Sequence B should start with no undo history")

command_manager.activate_timeline_stack("default_sequence")
assert(not command_manager.can_undo(), "Switching back should restore default sequence position")

print("✅ command_manager restores per-sequence undo positions")
