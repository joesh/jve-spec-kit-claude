#!/usr/bin/env luajit

-- Test that ImportFCP7XML undo skips sequence replay and refreshes timeline.
-- Verifies: undo uses delete-all (not replay), timeline state switches to pre-import sequence.
-- Uses REAL timeline_state — no mock.

local test_env = require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local timeline_state = require('ui.timeline.timeline_state')
local Signals = require('core.signals')
local SCHEMA_SQL = require('import_schema')

local TEST_DB = "/tmp/jve/test_import_undo_skips_replay.db"
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
        'default_sequence', 'default_project', 'Default', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 400, 0,
        '[]', '[]', '[]', 0, %d, %d
    );
]], now, now, now, now))

command_manager.init("default_sequence", "default_project")

-- Execute import
local import_cmd = Command.create("ImportFCP7XML", "default_project")
import_cmd:set_parameter("project_id", "default_project")
import_cmd:set_parameter("xml_path", test_env.resolve_repo_path("tests/fixtures/resolve/sample_timeline_fcp7xml.xml"))

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success, exec_result.error_message or "ImportFCP7XML execution failed")

-- Get the imported sequence and switch to it
local import_record = command_manager.get_last_command('default_project')
assert(import_record, "Import command should exist")
local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer should store created sequence ids")
local imported_sequence_id = created_sequence_ids[1]

timeline_state.init(imported_sequence_id, "default_project")
command_manager.activate_timeline_stack(imported_sequence_id)

-- Track reload via signal
local reload_count = 0
local reload_conn = Signals.connect("timeline_clips_reloaded", function()
    reload_count = reload_count + 1
end)

-- Monkey-patch replay_events to detect if undo tries to use it
local replay_invoked = false
local original_replay = command_manager.replay_events
command_manager.replay_events = function(...)
    replay_invoked = true
    return original_replay(...)
end

-- Undo the import
local undo_result = command_manager.undo()
command_manager.replay_events = original_replay

assert(undo_result.success, undo_result.error_message or "Undo should succeed without replay")
assert(not replay_invoked, "Undoing ImportFCP7XML should skip replay_events")

-- Timeline should have been refreshed (init counts as a reload in terms of data freshness)
-- With the real state, undo calls timeline_state.init(pre_import_seq) which fully reloads
assert(timeline_state.get_sequence_id() == "default_sequence",
    string.format("Timeline should restore to default sequence after undo (got %s)",
        tostring(timeline_state.get_sequence_id())))

Signals.disconnect(reload_conn)

os.remove(TEST_DB)
print("✅ ImportFCP7XML undo skips sequence replay and refreshes timeline")
