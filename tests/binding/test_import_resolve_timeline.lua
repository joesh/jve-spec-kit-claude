#!/usr/bin/env luajit

-- ImportResolveTimeline command test.
--
-- Verb semantics: import DRT sequences into the CURRENT project (no new
-- project created). Contrast with ImportResolveProject which creates a new
-- project. Undo removes the imported sequences/media/etc. but preserves
-- the target project.

local test_env = require('test_env')
local ui       = require('integration.ui_test_env')

print("=== test_import_resolve_timeline ===")

local DB = "/tmp/jve/test_import_resolve_timeline.jvp"
local _, info = ui.launch({
    db_path      = DB,
    project_name = "Host Project",
})

local database        = require("core.database")
local command_manager = require("core.command_manager")
local Command         = require("command")

local fixture_path = test_env.require_fixture(
    "tests/fixtures/resolve/retime-test.drt")

local function scalar(sql, param)
    local db = database.get_connection()
    local stmt = assert(db:prepare(sql), "prepare failed for: " .. sql)
    if param then stmt:bind_value(1, param) end
    assert(stmt:exec(), "exec failed for: " .. sql)
    local value = nil
    if stmt:next() then value = stmt:value(0) end
    stmt:finalize()
    return value
end

local sequences_before = scalar(
    "SELECT COUNT(*) FROM sequences WHERE project_id = ?", info.project.id)
local projects_before = scalar("SELECT COUNT(*) FROM projects")

local cmd = Command.create("ImportResolveTimeline", info.project.id)
cmd:set_parameter("drt_path", fixture_path)

local exec_result = command_manager.execute(cmd)
assert(exec_result and exec_result.success, "command executed")

-- Invariant 1: NO new project created.
local projects_after = scalar("SELECT COUNT(*) FROM projects")
assert(projects_after == projects_before, "no new project created by import")

-- Invariant 2: new sequences belong to the host project.
local sequences_after = scalar(
    "SELECT COUNT(*) FROM sequences WHERE project_id = ?", info.project.id)
assert(sequences_after > sequences_before,
    "imported sequences attached to host project")

-- Invariant 3: imported sequences have tracks + clips.
local imported_filter = string.format(
    "project_id = '%s' AND id != '%s'", info.project.id, info.sequences[1].id)
local imported_track_count = scalar(
    "SELECT COUNT(*) FROM tracks WHERE sequence_id IN " ..
    "(SELECT id FROM sequences WHERE " .. imported_filter .. ")")
assert(imported_track_count > 0, "imported tracks exist")

local imported_clip_count = scalar(
    "SELECT COUNT(*) FROM clips WHERE track_id IN " ..
    "(SELECT id FROM tracks WHERE sequence_id IN " ..
    "(SELECT id FROM sequences WHERE " .. imported_filter .. "))")
assert(imported_clip_count > 0, "imported clips exist")

-- Invariant 4: undo removes imported entities, host project survives.
local undo_result = command_manager.undo()
assert(undo_result and undo_result.success, "undo succeeded")

assert(scalar("SELECT COUNT(*) FROM projects") == projects_before,
    "host project count survives undo")
assert(scalar("SELECT COUNT(*) FROM projects WHERE id = ?", info.project.id) == 1,
    "host project row still present after undo")
assert(scalar("SELECT COUNT(*) FROM sequences WHERE project_id = ?",
        info.project.id) == sequences_before,
    "imported sequences removed on undo")
assert(scalar("SELECT COUNT(*) FROM sequences WHERE id = ?",
        info.sequences[1].id) == 1,
    "host sequence preserved after undo")

-- Invariant 5: redo re-imports.
local redo_result = command_manager.redo()
assert(redo_result and redo_result.success, "redo succeeded")
assert(scalar("SELECT COUNT(*) FROM sequences WHERE project_id = ?",
        info.project.id) == sequences_after,
    "redo restores imported sequences")

print("✅ test_import_resolve_timeline.lua passed")
