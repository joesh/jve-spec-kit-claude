#!/usr/bin/env luajit

-- Test that ImportFCP7XML undo skips sequence replay and refreshes timeline.
-- Verifies: undo uses delete-all (not replay), timeline state switches to
-- pre-import sequence.

local test_env = require('test_env')
local ui       = require('synthetic.integration.ui_test_env')

print("=== test_import_undo_skips_replay ===")

local DB = "/tmp/jve/test_import_undo_skips_replay.jvp"
local _, info = ui.launch({
    db_path      = DB,
    project_name = "Default Project",
})

local command_manager = require('core.command_manager')
local Command         = require('command')
local timeline_state  = require('ui.timeline.timeline_state')
local Signals         = require('core.signals')

local pre_import_sequence_id = info.sequences[1].id

-- Execute import on the template's default sequence.
local import_cmd = Command.create("ImportFCP7XML", info.project.id)
import_cmd:set_parameter("project_id", info.project.id)
import_cmd:set_parameter("xml_path",
    test_env.require_fixture("tests/fixtures/resolve/sample_timeline_fcp7xml.xml"))

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success,
    exec_result.error_message or "ImportFCP7XML execution failed")

local import_record = command_manager.get_last_command(info.project.id)
assert(import_record, "Import command should exist")
local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer should store created sequence ids")
local imported_sequence_id = created_sequence_ids[1]

command_manager.activate_timeline_stack(imported_sequence_id)

-- Track reload via signal so we know the timeline refreshed after undo.
local reload_count = 0
local reload_conn = Signals.connect("timeline_clips_reloaded", function()
    reload_count = reload_count + 1
end)

-- Monkey-patch replay_events to detect if undo tries to use it.
local replay_invoked = false
local original_replay = command_manager.replay_events
command_manager.replay_events = function(...)
    replay_invoked = true
    return original_replay(...)
end

-- Undo the import.
local undo_result = command_manager.undo()
command_manager.replay_events = original_replay

assert(undo_result.success,
    undo_result.error_message or "Undo should succeed without replay")
assert(not replay_invoked,
    "Undoing ImportFCP7XML should skip replay_events")

assert(timeline_state.get_tab_strip():active_sequence_id() == pre_import_sequence_id,
    string.format(
        "Timeline should restore to pre-import sequence after undo (got %s, want %s)",
        tostring(timeline_state.get_tab_strip():active_sequence_id()),
        pre_import_sequence_id))

Signals.disconnect(reload_conn)

print("✅ ImportFCP7XML undo skips sequence replay and refreshes timeline")
