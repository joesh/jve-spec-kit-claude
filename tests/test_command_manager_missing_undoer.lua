#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")

local DB = "/tmp/jve/test_command_manager_missing_undoer.db"
os.remove(DB)
assert(database.init(DB))
local db = database.get_connection()
db:exec(require("import_schema"))
command_manager.init("default_sequence", "default_project")

-- Register a dummy executor without an undoer to ensure undo fails loudly.
command_manager.register_executor("NoUndoCommand", function(cmd)
    return true
end, nil, {
    args = {
        project_id = { required = true },
    }
})

local cmd = Command.create("NoUndoCommand", "default_project")
local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "NoUndoCommand execute failed unexpectedly")

local undo_result = command_manager.undo()
assert(undo_result.success == false, "Undo should fail when no undoer is registered")
assert(undo_result.error_message and undo_result.error_message:find("No undoer"), "Undo error should mention missing undoer")

print("✅ Missing-undoer detection works")
