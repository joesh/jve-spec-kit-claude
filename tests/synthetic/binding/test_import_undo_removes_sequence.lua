#!/usr/bin/env luajit

-- Regression: importing a sequence and undoing back to the root should remove
-- the imported timeline and its media instead of leaving an empty shell behind.

local test_env = require("test_env")
local ui       = require("synthetic.integration.ui_test_env")

print("=== test_import_undo_removes_sequence ===")

local DB = "/tmp/jve/test_import_undo_removes_sequence.jvp"
local _, info = ui.launch({
    db_path      = DB,
    project_name = "Default Project",
})

local command_manager = require("core.command_manager")
local Command         = require("command")
local database        = require("core.database")

local function scalar(sql)
    local db = database.get_connection()
    local stmt = assert(db:prepare(sql), "Failed to prepare: " .. sql)
    local result = 0
    if stmt:exec() and stmt:next() then
        result = stmt:value(0) or 0
    end
    stmt:finalize()
    return result
end

local pre_import_sequences = scalar(
    "SELECT COUNT(*) FROM sequences WHERE kind = 'sequence'")
local pre_import_media = scalar("SELECT COUNT(*) FROM media")

command_manager.activate_timeline_stack(info.sequences[1].id)

local fixture_path = test_env.require_fixture(
    "tests/fixtures/resolve/sample_timeline_fcp7xml.xml")

local import_cmd = Command.create("ImportFCP7XML", info.project.id)
import_cmd:set_parameter("project_id", info.project.id)
import_cmd:set_parameter("xml_path", fixture_path)

local exec_result = command_manager.execute(import_cmd)
assert(exec_result.success, "ImportFCP7XML command should succeed")

local post_import_sequences = scalar(
    "SELECT COUNT(*) FROM sequences WHERE kind = 'sequence'")
assert(post_import_sequences > pre_import_sequences,
    string.format("Import should add timeline sequences (pre=%d post=%d)",
        pre_import_sequences, post_import_sequences))

local imported_named = scalar(
    "SELECT COUNT(*) FROM sequences WHERE name = 'Timeline 1 (Resolve)'")
assert(imported_named == 1, "Imported sequence should be present after import")

local undo_result = command_manager.undo()
assert(undo_result.success, "Undoing the import should succeed: " ..
    tostring(undo_result.error_message or undo_result.error))

local sequences_after = scalar(
    "SELECT COUNT(*) FROM sequences WHERE kind = 'sequence'")
assert(sequences_after == pre_import_sequences,
    string.format("Undo should restore sequence count (%d vs pre=%d)",
        sequences_after, pre_import_sequences))

local imported_named_after = scalar(
    "SELECT COUNT(*) FROM sequences WHERE name = 'Timeline 1 (Resolve)'")
assert(imported_named_after == 0, "Imported sequence should be gone after undo")

local media_after = scalar("SELECT COUNT(*) FROM media")
assert(media_after == pre_import_media,
    string.format("Undo should restore media count (%d vs pre=%d)",
        media_after, pre_import_media))

print("✅ Import undo removes generated timeline and media")
