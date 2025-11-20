#!/usr/bin/env luajit

-- BatchCommand parameter/transaction contract using current schema.

package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

-- Minimal Qt stubs used by timeline_state during command execution
_G.qt_json_encode = _G.qt_json_encode or function(_) return "{}" end
_G.qt_create_single_shot_timer = _G.qt_create_single_shot_timer or function(_, cb) cb(); return {} end

local function assert_true(label, value)
    if not value then
        io.stderr:write(label .. "\n")
        os.exit(1)
    end
end

local function assert_eq(label, actual, expected)
    if actual ~= expected then
        io.stderr:write(string.format("%s: expected %s, got %s\n", label, tostring(expected), tostring(actual)))
        os.exit(1)
    end
end

local db_path = os.tmpname() .. ".jvp"
os.remove(db_path)
assert_true("set_path", database.set_path(db_path))
local db = database.get_connection()
assert_true("db connection", db ~= nil)
_G.db = db

local schema = [[
CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, created_at INTEGER, modified_at INTEGER, settings TEXT);
CREATE TABLE sequences (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  name TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'timeline',
  frame_rate REAL NOT NULL,
  audio_rate REAL NOT NULL DEFAULT 48000,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  timecode_start INTEGER NOT NULL DEFAULT 0,
  playhead_time INTEGER NOT NULL DEFAULT 0,
  selected_clip_ids TEXT DEFAULT '[]',
  selected_edge_infos TEXT DEFAULT '[]',
  viewport_start_time INTEGER NOT NULL DEFAULT 0,
  viewport_duration INTEGER NOT NULL DEFAULT 10000,
  mark_in_time INTEGER,
  mark_out_time INTEGER,
  current_sequence_number INTEGER
);
CREATE TABLE tracks (
  id TEXT PRIMARY KEY,
  sequence_id TEXT NOT NULL,
  name TEXT,
  track_type TEXT NOT NULL,
  timebase_type TEXT NOT NULL DEFAULT 'video_frames',
  timebase_rate REAL NOT NULL DEFAULT 30.0,
  track_index INTEGER NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  locked INTEGER NOT NULL DEFAULT 0,
  muted INTEGER NOT NULL DEFAULT 0,
  soloed INTEGER NOT NULL DEFAULT 0,
  volume REAL NOT NULL DEFAULT 1.0,
  pan REAL NOT NULL DEFAULT 0.0
);
CREATE TABLE clips (
  id TEXT PRIMARY KEY,
  project_id TEXT,
  clip_kind TEXT NOT NULL DEFAULT 'timeline',
  name TEXT DEFAULT '',
  track_id TEXT,
  media_id TEXT,
  source_sequence_id TEXT,
  parent_clip_id TEXT,
  owner_sequence_id TEXT,
  start_time INTEGER NOT NULL,
  duration INTEGER NOT NULL,
  source_in INTEGER NOT NULL DEFAULT 0,
  source_out INTEGER NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  offline INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL DEFAULT 0,
  modified_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE media (
  id TEXT PRIMARY KEY,
  project_id TEXT,
  name TEXT,
  file_path TEXT,
  file_name TEXT NOT NULL DEFAULT '',
  duration INTEGER,
  frame_rate REAL,
  width INTEGER,
  height INTEGER,
  audio_channels INTEGER,
  codec TEXT,
  created_at INTEGER NOT NULL DEFAULT 0,
  modified_at INTEGER NOT NULL DEFAULT 0,
  metadata TEXT DEFAULT '{}'
);
CREATE TABLE commands (
  id TEXT PRIMARY KEY,
  parent_id TEXT,
  parent_sequence_number INTEGER,
  sequence_number INTEGER,
  command_type TEXT NOT NULL,
  command_args TEXT,
  pre_hash TEXT,
  post_hash TEXT,
  timestamp INTEGER,
  playhead_time INTEGER DEFAULT 0,
  selected_clip_ids TEXT DEFAULT '[]',
  selected_edge_infos TEXT DEFAULT '[]',
  selected_clip_ids_pre TEXT DEFAULT '[]',
  selected_edge_infos_pre TEXT DEFAULT '[]'
);
]]

for stmt in schema:gmatch("[^;]+;") do
    local s = db:prepare(stmt)
    assert_true("prepare schema", s ~= nil)
    assert_true("exec schema", s:exec())
    s:finalize()
end

db:exec("INSERT INTO projects (id, name, settings) VALUES ('default_project','BatchCmd','{}')")
db:exec("INSERT INTO sequences (id, project_id, name, frame_rate, width, height) VALUES ('default_sequence','default_project','Seq',30,1920,1080)")

command_manager.init(db)

-- Test 1: accepts commands_json parameter
do
    local cmd = Command.create("BatchCommand", "default_project")
    cmd:set_parameter("commands_json", "[]")
    cmd:set_parameter("sequence_id", "default_sequence")
    local result = command_manager.execute(cmd)
    assert_true("BatchCommand accepts commands_json", result.success)
end

-- Test 2: wrong parameter name should fail gracefully
do
    local cmd = Command.create("BatchCommand", "default_project")
    cmd:set_parameter("commands", "[]")
    cmd:set_parameter("sequence_id", "default_sequence")
    local result = command_manager.execute(cmd)
    assert_true("BatchCommand rejects wrong param name", result.success == false)
end

-- Test 3: transaction rollback on failure (inject bad command)
do
    local cmd = Command.create("BatchCommand", "default_project")
    cmd:set_parameter("commands_json", [=[[{"command_type":"CreateSequence","args":{}}]]=])
    cmd:set_parameter("sequence_id", "default_sequence")
    local result = command_manager.execute(cmd)
    assert_true("BatchCommand rollback failure", result.success == false)
end

-- Test 4: empty array handled
do
    local cmd = Command.create("BatchCommand", "default_project")
    cmd:set_parameter("commands_json", "[]")
    cmd:set_parameter("sequence_id", "default_sequence")
    local result = command_manager.execute(cmd)
    assert_true("BatchCommand empty array", result.success)
end

print("✅ BatchCommand contract tests passed")
