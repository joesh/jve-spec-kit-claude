#!/usr/bin/env luajit

-- Resolve .drp importer + command regression test

package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path

function qt_json_encode(_) return "{}" end
function qt_create_single_shot_timer(_, cb) cb(); return {} end

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

local fixture_path = "tests/fixtures/resolve/sample_project.drp"

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
assert_true("clip duration", clip.duration and clip.duration > 0)

-- Execute full command pipeline against a scratch database
local tmp_path = os.tmpname() .. ".jvp"
os.remove(tmp_path)
assert_true("set_path", database.set_path(tmp_path))
local db = database.get_connection()
assert_true("db connection", db ~= nil)

local schema_statements = {
    [[CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        settings TEXT
    )]],
    [[CREATE TABLE sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        name TEXT,
        frame_rate REAL,
        width INTEGER,
        height INTEGER,
        timecode_start INTEGER,
        playhead_time INTEGER,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        current_sequence_number INTEGER
    )]],
    [[CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT,
        name TEXT,
        track_type TEXT,
        track_index INTEGER,
        enabled INTEGER,
        locked INTEGER,
        muted INTEGER,
        soloed INTEGER,
        volume REAL,
        pan REAL
    )]],
    [[CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        name TEXT,
        file_path TEXT,
        duration INTEGER,
        frame_rate REAL,
        width INTEGER,
        height INTEGER,
        audio_channels INTEGER,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT
    )]],
    [[CREATE TABLE clips (
        id TEXT PRIMARY KEY,
        track_id TEXT,
        media_id TEXT,
        start_time INTEGER,
        duration INTEGER,
        source_in INTEGER,
        source_out INTEGER,
        enabled INTEGER
    )]],
    [[CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER,
        command_type TEXT,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_time INTEGER,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        selected_clip_ids_pre TEXT,
        selected_edge_infos_pre TEXT
    )]]
}

for _, statement in ipairs(schema_statements) do
    exec_sql(db, statement)
end

exec_sql(db, "INSERT INTO projects VALUES ('default_project','Default',0,0,'{}')")
exec_sql(db, "INSERT INTO sequences VALUES ('default_sequence','default_project','Default Timeline','timeline',30,1920,1080,0,0,'[]','[]',NULL)")

command_manager.init(db)

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
