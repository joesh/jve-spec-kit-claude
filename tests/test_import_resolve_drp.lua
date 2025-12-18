#!/usr/bin/env luajit

-- Resolve .drp importer + command regression test

require('test_env')

local drp_importer = require("importers.drp_importer")
local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

local function assert_eq(label, actual, expected)
    if actual ~= expected then
        io.stderr:write(string.format("%s: expected %s, got %s\n", label, tostring(expected), tostring(actual)))
        os.exit(1)
    end
end

local function assert_true(label, value)
    if not value then
        io.stderr:write(label .. " failed\n")
        os.exit(1)
    end
end

local function exec_sql(db, sql)
    local stmt = db:prepare(sql)
    assert_true("prepare failed for: " .. sql, stmt ~= nil)
    assert_true("exec failed for: " .. sql, stmt:exec())
    stmt:finalize()
end

local function scalar(db, sql, param)
    local stmt = db:prepare(sql)
    assert_true("prepare failed for: " .. sql, stmt ~= nil)
    if param then
        stmt:bind_value(1, param)
    end
    assert_true("exec failed for: " .. sql, stmt:exec())
    local value = nil
    if stmt:next() then
        value = stmt:value(0)
    end
    stmt:finalize()
    return value
end

local fixture_path = "fixtures/resolve/sample_project.drp"

-- Validate raw parser behaviour
local parse_result = drp_importer.parse_drp_file(fixture_path)
assert_true("parse_drp_file success", parse_result and parse_result.success)
assert_true("project metadata present", parse_result.project ~= nil)
assert_true("project name", (parse_result.project.name or ""):len() > 0)
assert_true("project frame rate", parse_result.project.settings and parse_result.project.settings.frame_rate and parse_result.project.settings.frame_rate > 0)
assert_true("media items parsed", type(parse_result.media_items) == "table")
assert_true("has media items", #parse_result.media_items > 0)
assert_true("timelines parsed", type(parse_result.timelines) == "table")
assert_true("at least one timeline", #parse_result.timelines > 0)

local timeline = parse_result.timelines[1]
assert_true("timeline name", (timeline.name or ""):len() > 0)
assert_true("timeline has tracks", type(timeline.tracks) == "table" and #timeline.tracks > 0)
local track = timeline.tracks[1]
assert_true("track type", track.type == "VIDEO" or track.type == "AUDIO")
assert_true("track clips", type(track.clips) == "table" and #track.clips > 0)
local clip = track.clips[1]
assert_true("clip duration", clip.duration ~= nil)

-- Execute full command pipeline against a scratch database
local TEST_DB = "/tmp/jve/test_import_resolve_drp.db"
os.remove(TEST_DB)
database.init(TEST_DB)
local db = database.get_connection()
assert_true("db connection", db ~= nil)

-- Bootstrap schema using import_schema helper
local schema_sql = require('import_schema')
assert_true("schema creation", db:exec(schema_sql))

-- Add initial project data
local bootstrap_ok = db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
]])
assert_true("bootstrap project", bootstrap_ok)

-- Add default sequence
local seq_ok, seq_err = db:exec([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Default Timeline', 'timeline', 30, 1, 48000, 1920, 1080, strftime('%s','now'), strftime('%s','now'));
]])
if not seq_ok then
    io.stderr:write("Bootstrap sequence error: " .. tostring(seq_err) .. "\n")
    os.exit(1)
end

command_manager.init(db, 'default_sequence', 'default_project')

local cmd = Command.create("ImportResolveProject", "default_project")
cmd:set_parameter("drp_path", fixture_path)

local exec_result = command_manager.execute(cmd)
assert_true("command executed", exec_result and exec_result.success)
assert_true("command result stored", cmd.result and cmd.result.success)

local imported_project_id = cmd.result.project_id
assert_true("imported project id present", imported_project_id ~= nil)

local project_count = scalar(db, "SELECT COUNT(*) FROM projects")
assert_true("project count increased", project_count and project_count > 1)
assert_true(
    "resolve project name persisted",
    scalar(db, "SELECT COUNT(*) FROM projects WHERE name = 'resolve playground'") == 1
)

local sequence_count = scalar(db, "SELECT COUNT(*) FROM sequences WHERE project_id = ?", imported_project_id)
assert_true("sequences created", sequence_count and sequence_count > 0)

local track_count = scalar(db, "SELECT COUNT(*) FROM tracks WHERE sequence_id IN (SELECT id FROM sequences WHERE project_id = ?)", imported_project_id)
assert_true("tracks created", track_count and track_count > 0)

local clip_count = scalar(db, "SELECT COUNT(*) FROM clips WHERE track_id IN (SELECT id FROM tracks WHERE sequence_id IN (SELECT id FROM sequences WHERE project_id = ?))", imported_project_id)
assert_true("clips created", clip_count and clip_count > 0)

local media_count = scalar(db, "SELECT COUNT(*) FROM media WHERE project_id = ?", imported_project_id)
assert_true("media created", media_count and media_count > 0)

os.remove(tmp_path)

print("✅ Resolve .drp importer + command test passed")
