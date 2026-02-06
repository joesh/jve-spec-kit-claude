--- Test: batch_command undo propagates child undo failures
-- Regression: child undo failure was swallowed with print, parent returned true
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local command_undoers = {}
local command_executors = {}

-- Register a command type whose undo always fails
command_undoers["AlwaysFails"] = function(cmd)
    return false
end
command_executors["AlwaysFails"] = function(cmd)
    return true
end

-- Mock command_helper
package.loaded["core.command_helper"] = {
    add_delete_mutation = function() end,
    add_update_mutation = function() end,
    add_insert_mutation = function() end,
    clip_update_payload = function() return nil end,
    capture_clip_state = function() return {} end,
}

-- Load batch_command
local batch_command = require("core.commands.batch_command")
batch_command.register(command_executors, command_undoers, nil, function() end)

local Command = require("command")

-- Build a batch command that looks like it was already executed
-- (undo reads executed_commands_json, not command_specs)
local cmd = Command.create("BatchCommand", "proj1")
cmd:set_parameters({
    project_id = "proj1",
    executed_commands_json = qt_json_encode({
        { command_type = "AlwaysFails", parameters = { project_id = "proj1" }, project_id = "proj1" },
    }),
})

-- The undo should NOT return true when a child fails
local ok, result = pcall(function()
    return command_undoers["BatchCommand"](cmd)
end)

if ok then
    -- Didn't error — check return value
    check("batch undo must not return true when child fails", result ~= true)
else
    -- Errored — acceptable (fail-fast)
    check("batch undo errors on child failure", true)
end

if failed > 0 then
    print(string.format("❌ test_batch_command_undo_propagates.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_batch_command_undo_propagates.lua passed (%d assertions)", passed))
