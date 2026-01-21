#!/usr/bin/env luajit

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

local function create_schema(db)
    local SCHEMA_SQL = require("import_schema")
    assert(db:exec(SCHEMA_SQL))
end

local db_path = "/tmp/jve/test_command_manager_listeners.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
create_schema(db)

local now = os.time()
db:exec(string.format([[ 
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Listener Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height,
        timecode_start_frame, playhead_value, selected_clip_ids, selected_edge_infos,
        viewport_start_value, viewport_duration_frames_value, current_sequence_number)
    VALUES ('timeline_seq', 'test_project', 'Timeline Seq', 'timeline',
        24.0, 48000, 1920, 1080, 0, 0, '[]', '[]', 0, 240, NULL);
]], now, now))

command_manager.init("timeline_seq", "test_project")

local events = {}
local listener = function(evt)
    table.insert(events, evt)
end
command_manager.add_listener(listener)

command_manager.register_executor("TestNoOpListener", function()
    return true
end, function()
    return true
end, {
    args = {
        project_id = { required = true },
    }
})

local cmd = Command.create("TestNoOpListener", "test_project")
local exec_result = command_manager.execute(cmd)
assert(exec_result.success, "execute should succeed")
assert(#events >= 1, "listener should capture execute event")
assert(events[#events].event == "execute", "expected execute event")
assert(events[#events].command and events[#events].command.type == "TestNoOpListener", "execute event command type mismatch")
 
local undo_result = command_manager.undo()
assert(undo_result.success, "undo should succeed")
assert(events[#events].event == "undo", "expected undo event")
assert(events[#events].command and events[#events].command.type == "TestNoOpListener", "undo event command type mismatch")

local redo_result = command_manager.redo()
assert(redo_result.success, "redo should succeed")
assert(events[#events].event == "redo", "expected redo event")
assert(events[#events].command and events[#events].command.type == "TestNoOpListener", "redo event command type mismatch")

command_manager.unregister_executor("TestNoOpListener")
command_manager.remove_listener(listener)

print("✅ Command manager listeners triggered execute/undo/redo events")
