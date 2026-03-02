#!/usr/bin/env luajit

-- Regression test: ImportFCP7XML undo should restore pre-import active sequence
-- Bug: undo deletes imported sequence but leaves timeline_state pointing at it
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

local TEST_DB = "/tmp/jve/test_import_undo_restores_sequence.db"
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

-- Get the imported sequence
local import_record = command_manager.get_last_command('default_project')
local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer should store created sequence ids")
local imported_sequence_id = created_sequence_ids[1]

-- Switch timeline_state to imported sequence (simulating user clicking on it)
timeline_state.init(imported_sequence_id, "default_project")
command_manager.activate_timeline_stack(imported_sequence_id)
assert(timeline_state.get_sequence_id() == imported_sequence_id,
    "Precondition: timeline should be viewing imported sequence")

-- Track reloads via signal
local reload_count = 0
local reload_conn = Signals.connect("timeline_clips_reloaded", function()
    reload_count = reload_count + 1
end)

-- Undo the import — deletes the imported sequence
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")

-- KEY ASSERTION: timeline_state must NOT point at the deleted sequence
assert(timeline_state.get_sequence_id() ~= imported_sequence_id,
    string.format("BUG: timeline_state still pointing at deleted sequence %s", imported_sequence_id))

-- It should be back on the pre-import sequence
assert(timeline_state.get_sequence_id() == "default_sequence",
    string.format("Expected default_sequence after undo, got %s",
        tostring(timeline_state.get_sequence_id())))

Signals.disconnect(reload_conn)

os.remove(TEST_DB)
print("✅ ImportFCP7XML undo restores pre-import active sequence")
