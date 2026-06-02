#!/usr/bin/env luajit

-- Regression: undoing an FCP7 XML import while focused on the imported sequence
-- should not strand the redo stack. Redo must recreate the sequence, tracks,
-- and clips even though the timeline stack points at a deleted sequence ID.

require('test_env')

local test_env = require('test_env')
local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local blank_project = require('helpers.blank_project')

local function count_rows(db, table_name)
    local stmt = db:prepare("SELECT COUNT(*) FROM " .. table_name)
    assert(stmt, "Failed to prepare count for " .. tostring(table_name))
    assert(stmt:exec() and stmt:next(), "Failed to execute count for " .. tostring(table_name))
    local value = stmt:value(0) or 0
    stmt:finalize()
    return value
end

local info = blank_project.open_fresh("/tmp/jve/test_import_redo_restores_sequence.jvp")
local db = database.get_connection()
command_manager.activate_timeline_stack(info.sequence_id)

-- Capture the post-template, pre-import state. The Film 24fps template ships
-- with one sequence and a fixed set of V/A tracks (no clips). Undo must
-- restore TO this state — not to a row-empty state.
local pre_import_counts = {
    sequences = count_rows(db, "sequences"),
    tracks    = count_rows(db, "tracks"),
    clips     = count_rows(db, "clips"),
}

local import_cmd = Command.create("ImportFCP7XML", info.project_id)
import_cmd:set_parameter("project_id", info.project_id)
import_cmd:set_parameter("xml_path", test_env.require_fixture("tests/fixtures/resolve/sample_timeline_fcp7xml.xml"))

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success, exec_result.error_message or "ImportFCP7XML execution failed")

local import_record = command_manager.get_last_command(info.project_id)
assert(import_record, "Import command not recorded in log")

local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer should store created sequence IDs")
local imported_sequence_id = created_sequence_ids[1]

local baseline_counts = {
    sequences = count_rows(db, "sequences"),
    tracks = count_rows(db, "tracks"),
    clips = count_rows(db, "clips")
}

command_manager.activate_timeline_stack(imported_sequence_id)

local clip_stmt = db:prepare("SELECT id FROM clips WHERE owner_sequence_id = ? LIMIT 1")
clip_stmt:bind_value(1, imported_sequence_id)
assert(clip_stmt:exec() and clip_stmt:next(), "Failed to fetch clip from imported sequence")
local imported_clip_id = clip_stmt:value(0)
clip_stmt:finalize()

local toggle_cmd = Command.create("ToggleClipEnabled", info.project_id)
toggle_cmd:set_parameter("sequence_id", imported_sequence_id)
toggle_cmd:set_parameter("clip_ids", { imported_clip_id })
local toggle_result = command_manager.execute(toggle_cmd)
assert(toggle_result.success, "ToggleClipEnabled should succeed on imported clip")

assert(command_manager.undo().success, "Undo ToggleClipEnabled should succeed")
assert(command_manager.undo().success, "Undo ImportFCP7XML should succeed even from deleted stack")

local after_undo_counts = {
    sequences = count_rows(db, "sequences"),
    tracks = count_rows(db, "tracks"),
    clips = count_rows(db, "clips")
}
-- Undo must restore the template's post-OpenProject state — sequence,
-- track, and clip counts back to what blank_project.open_fresh left.
assert(after_undo_counts.sequences == pre_import_counts.sequences,
    string.format("Undo should restore sequence count (%d vs pre=%d)",
        after_undo_counts.sequences, pre_import_counts.sequences))
assert(after_undo_counts.tracks == pre_import_counts.tracks,
    string.format("Undo should restore track count (%d vs pre=%d)",
        after_undo_counts.tracks, pre_import_counts.tracks))
assert(after_undo_counts.clips == pre_import_counts.clips,
    string.format("Undo should restore clip count (%d vs pre=%d)",
        after_undo_counts.clips, pre_import_counts.clips))

-- UI would still be focused on the (now deleted) imported timeline stack.
command_manager.activate_timeline_stack(imported_sequence_id)

local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo import should succeed")

local after_redo_counts = {
    sequences = count_rows(db, "sequences"),
    tracks = count_rows(db, "tracks"),
    clips = count_rows(db, "clips")
}

assert(after_redo_counts.sequences == baseline_counts.sequences,
    string.format("Redo should restore sequence count (%d vs %d)", after_redo_counts.sequences, baseline_counts.sequences))
assert(after_redo_counts.tracks == baseline_counts.tracks,
    string.format("Redo should restore track count (%d vs %d)", after_redo_counts.tracks, baseline_counts.tracks))
assert(after_redo_counts.clips == baseline_counts.clips,
    string.format("Redo should restore clip count (%d vs %d)", after_redo_counts.clips, baseline_counts.clips))

blank_project.cleanup("/tmp/jve/test_import_redo_restores_sequence.jvp")
print("✅ Redo after ImportFCP7XML restores deleted sequence state")
