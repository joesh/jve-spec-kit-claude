#!/usr/bin/env luajit

-- BatchCommand parameter/transaction contract using current schema.

package.path = "tests/?.lua;tests/?/init.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local schema = require("import_schema")

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

do
    local ok, err = db:exec(schema)
    if ok == false then
        io.stderr:write("exec schema failed: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

local now = os.time()
db:exec(string.format("INSERT INTO projects (id, name, created_at, modified_at, settings) VALUES ('default_project','BatchCmd',%d,%d,'{}')", now, now))
db:exec(string.format([[
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
        width, height, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        view_start_frame, view_duration_frames, created_at, modified_at
    ) VALUES (
        'default_sequence', 'default_project', 'Seq', 'timeline', 30, 1, 48000,
        1920, 1080, 0,
        '[]', '[]', '[]',
        0, 240, %d, %d
    )
]], now, now))

db:exec(string.format("INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('v1','default_sequence','V1','VIDEO',1,1)"))

command_manager.init(db, "default_sequence", "default_project")

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
