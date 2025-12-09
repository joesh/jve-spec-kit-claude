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
