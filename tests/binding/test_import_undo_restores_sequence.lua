#!/usr/bin/env luajit

-- Regression test: ImportFCP7XML undo should restore pre-import active sequence
-- Bug: undo deletes imported sequence but leaves timeline_state pointing at it

local test_env = require('test_env')
local ui       = require('integration.ui_test_env')

_G.qt_create_single_shot_timer = function() end

print("=== test_import_undo_restores_sequence ===")

local DB = "/tmp/jve/test_import_undo_restores_sequence.jvp"
local _, info = ui.launch({
    db_path      = DB,
    project_name = "Default Project",
})

local command_manager = require('core.command_manager')
local Command         = require('command')
local timeline_state  = require('ui.timeline.timeline_state')
local Signals         = require('core.signals')

local pre_import_sequence_id = info.sequences[1].id

local import_cmd = Command.create("ImportFCP7XML", info.project.id)
import_cmd:set_parameter("project_id", info.project.id)
import_cmd:set_parameter("xml_path",
    test_env.require_fixture("tests/fixtures/resolve/sample_timeline_fcp7xml.xml"))

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success,
    exec_result.error_message or "ImportFCP7XML execution failed")

local import_record = command_manager.get_last_command(info.project.id)
local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer should store created sequence ids")
local imported_sequence_id = created_sequence_ids[1]

-- Switch to imported sequence (simulating user clicking the new tab).
command_manager.activate_timeline_stack(imported_sequence_id)
assert(timeline_state.get_tab_strip():active_sequence_id() == imported_sequence_id,
    "Precondition: timeline should be viewing imported sequence")

local reload_count = 0
local reload_conn = Signals.connect("timeline_clips_reloaded", function()
    reload_count = reload_count + 1
end)

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")

-- KEY ASSERTION: timeline_state must NOT point at the deleted sequence.
assert(timeline_state.get_tab_strip():active_sequence_id() ~= imported_sequence_id,
    string.format("BUG: timeline_state still pointing at deleted sequence %s",
        imported_sequence_id))

-- It should be back on the pre-import sequence.
assert(timeline_state.get_tab_strip():active_sequence_id() == pre_import_sequence_id,
    string.format("Expected pre-import sequence after undo, got %s",
        tostring(timeline_state.get_tab_strip():active_sequence_id())))

Signals.disconnect(reload_conn)

print("✅ ImportFCP7XML undo restores pre-import active sequence")
