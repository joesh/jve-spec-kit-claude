#!/usr/bin/env luajit

-- ImportResolveTimeline command test.
--
-- Verb semantics: import DRT sequences into the CURRENT project (no new
-- project created). Contrast with ImportResolveProject which creates a new
-- project. Undo removes the imported sequences/media/etc. but preserves
-- the target project.

require('test_env')

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

local function fail(label)
    io.stderr:write(label .. "\n")
    os.exit(1)
end

local function assert_true(label, value)
    if not value then fail(label .. " failed") end
end

local function scalar(db, sql, param)
    local stmt = db:prepare(sql)
    assert_true("prepare failed for: " .. sql, stmt ~= nil)
    if param then stmt:bind_value(1, param) end
    assert_true("exec failed for: " .. sql, stmt:exec())
    local value = nil
    if stmt:next() then value = stmt:value(0) end
    stmt:finalize()
    return value
end

local test_env = require('test_env')
local fixture_path = test_env.require_fixture(
    "tests/fixtures/resolve/retime-test.drt")

-- Scratch DB with a pre-existing project the user is "working in"
local TEST_DB = "/tmp/jve/test_import_resolve_timeline.db"
os.remove(TEST_DB)
database.init(TEST_DB)
local db = database.get_connection()
assert_true("db connection", db ~= nil)

local schema_sql = require('import_schema')
assert_true("schema creation", db:exec(schema_sql))

assert_true("bootstrap project", db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('host_project', 'Host Project', 0, 0);
]]))
assert_true("bootstrap sequence", db:exec([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('host_sequence', 'host_project', 'Host Timeline', 'timeline', 30, 1, 48000, 1920, 1080, 0, 0);
]]))

command_manager.init('host_sequence', 'host_project')

-- Baseline counts BEFORE import
local sequences_before = scalar(db, "SELECT COUNT(*) FROM sequences WHERE project_id = ?", 'host_project')
local projects_before = scalar(db, "SELECT COUNT(*) FROM projects")
assert_true("host project has 1 sequence to start", sequences_before == 1)
assert_true("exactly one project before import", projects_before == 1)

-- Execute the new command
local cmd = Command.create("ImportResolveTimeline", "host_project")
cmd:set_parameter("drt_path", fixture_path)

local exec_result = command_manager.execute(cmd)
assert_true("command executed", exec_result and exec_result.success)

-- Invariant 1: NO new project created (the defining semantic of this verb)
local projects_after = scalar(db, "SELECT COUNT(*) FROM projects")
assert_true("no new project created by import", projects_after == projects_before)

-- Invariant 2: new sequences belong to the existing project
local sequences_after = scalar(db, "SELECT COUNT(*) FROM sequences WHERE project_id = ?", 'host_project')
assert_true("imported sequences attached to host project",
    sequences_after and sequences_after > sequences_before)

-- Invariant 3: imported sequences contain tracks and clips
local imported_seq_filter = "project_id = 'host_project' AND id != 'host_sequence'"
local imported_track_count = scalar(db,
    "SELECT COUNT(*) FROM tracks WHERE sequence_id IN (SELECT id FROM sequences WHERE " .. imported_seq_filter .. ")")
assert_true("imported tracks exist", imported_track_count and imported_track_count > 0)

local imported_clip_count = scalar(db,
    "SELECT COUNT(*) FROM clips WHERE track_id IN (SELECT id FROM tracks WHERE sequence_id IN (SELECT id FROM sequences WHERE " .. imported_seq_filter .. "))")
assert_true("imported clips exist", imported_clip_count and imported_clip_count > 0)

-- Invariant 4: undo removes imported entities but NOT the host project
assert_true("undo succeeded", command_manager.undo())

local projects_after_undo = scalar(db, "SELECT COUNT(*) FROM projects")
assert_true("host project survives undo", projects_after_undo == projects_before)

local host_project_still_exists = scalar(db,
    "SELECT COUNT(*) FROM projects WHERE id = 'host_project'")
assert_true("host project row still present after undo",
    host_project_still_exists == 1)

local sequences_after_undo = scalar(db,
    "SELECT COUNT(*) FROM sequences WHERE project_id = ?", 'host_project')
assert_true("imported sequences removed on undo",
    sequences_after_undo == sequences_before)

local host_sequence_still_exists = scalar(db,
    "SELECT COUNT(*) FROM sequences WHERE id = 'host_sequence'")
assert_true("host sequence preserved after undo",
    host_sequence_still_exists == 1)

-- Invariant 5: redo re-imports
assert_true("redo succeeded", command_manager.redo())
local sequences_after_redo = scalar(db,
    "SELECT COUNT(*) FROM sequences WHERE project_id = ?", 'host_project')
assert_true("redo restores imported sequences",
    sequences_after_redo == sequences_after)

os.remove(TEST_DB)

print("✅ test_import_resolve_timeline.lua passed")
