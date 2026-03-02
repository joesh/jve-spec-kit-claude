#!/usr/bin/env luajit

-- Regression test: Redo should restore the post-execution playhead position
-- from the captured value, NOT by re-running executor logic.
--
-- This test verifies that playhead_value_post is captured and restored on redo,
-- independent of the executor's advance_playhead behavior.
-- Uses REAL timeline_state — no mock.

local test_env = require("test_env")

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_redo_playhead.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(SCHEMA_SQL)

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'seq1', 'default_project', 'Sequence', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 300, 0,
        '[]', '[]', '[]', 0, %d, %d
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator, created_at, modified_at)
    VALUES ('media1', 'default_project', '/tmp/test.mov', 'Test Media', 3000, 30, 1, %d, %d);
]], now, now, now, now, now, now))

command_manager.init("seq1", "default_project")

-- Create masterclip sequence for the media (required for Insert)
local master_clip_id = test_env.create_test_masterclip_sequence(
    'default_project', 'Test Media Master', 30, 1, 3000, 'media1')

print("=== Redo Playhead Position Regression Test ===")

-- Initial state: playhead at frame 0
assert(timeline_state.get_playhead_position() == 0, "Precondition: playhead at 0")

-- Execute Insert with advance_playhead=true
local insert_cmd = Command.create("Insert", "default_project")
insert_cmd:set_parameter("sequence_id", "seq1")
insert_cmd:set_parameter("track_id", "v1")
insert_cmd:set_parameter("master_clip_id", master_clip_id)
insert_cmd:set_parameter("insert_time", 0)
insert_cmd:set_parameter("duration", 100)
insert_cmd:set_parameter("source_in", 0)
insert_cmd:set_parameter("source_out", 100)
insert_cmd:set_parameter("advance_playhead", true)

print("Step 1: Execute Insert (100 frames at 0, advance_playhead=true)")
local result = command_manager.execute(insert_cmd)
assert(result.success, result.error_message or "Insert failed")

local post_exec = timeline_state.get_playhead_position()
print(string.format("  Post-execution playhead: %d (expected 100)", post_exec))
assert(post_exec == 100, string.format("Expected 100, got %d", post_exec))

-- Verify playhead_value_post captured in DB
print("Step 2: Verify playhead_value_post in DB")
local check_stmt = db:prepare("SELECT playhead_value_post FROM commands ORDER BY sequence_number DESC LIMIT 1")
assert(check_stmt and check_stmt:exec() and check_stmt:next(), "Failed to query commands")
local captured = check_stmt:value(0)
check_stmt:finalize()
assert(captured == 100, string.format("playhead_value_post should be 100, got %s", tostring(captured)))

-- Undo
print("Step 3: Undo")
result = command_manager.undo()
assert(result.success, result.error_message or "Undo failed")
local post_undo = timeline_state.get_playhead_position()
print(string.format("  Post-undo playhead: %d (expected 0)", post_undo))
assert(post_undo == 0, string.format("Expected 0, got %d", post_undo))

-- Redo — the key test
print("Step 4: Redo")
result = command_manager.redo()
assert(result.success, result.error_message or "Redo failed")
local post_redo = timeline_state.get_playhead_position()
print(string.format("  Post-redo playhead: %d (expected 100)", post_redo))
assert(post_redo == 100, string.format(
    "REGRESSION: Expected 100 after redo, got %d", post_redo))

-- Cleanup
os.remove(TEST_DB)
print("✅ test_redo_restores_post_execution_playhead.lua passed")
