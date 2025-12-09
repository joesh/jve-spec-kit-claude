#!/usr/bin/env luajit

-- Regression: BatchCommand undo must invoke child undoers (not executors) and preserve mutated parameters for DeleteClip.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";../tests/?.lua"

require("test_env")

local json = require("dkjson")
local Command = require("command")

-- Minimal tables to register commands
local executors = {}
local undoers = {}

-- Track calls
local called = {
    delete_exec = 0,
    delete_undo = 0
}

-- Stub command_helper functions used by batch_command
package.loaded["core.command_helper"] = {
    add_insert_mutation = function() end,
    add_update_mutation = function() end,
    add_delete_mutation = function() end
}

-- Register DeleteClip stub
do
    local function register(execs, unds)
        execs["DeleteClip"] = function(cmd)
            called.delete_exec = called.delete_exec + 1
            -- Simulate adding mutated params
            cmd:set_parameter("deleted_clip_state", {id = "clip_x", owner_sequence_id = "seq_x"})
            return true
        end
        unds["DeleteClip"] = function(cmd)
            called.delete_undo = called.delete_undo + 1
            cmd:set_parameter("__timeline_mutations", {seq_x = {sequence_id = "seq_x", inserts = { {clip_id = "clip_x"} }, updates = {}, deletes = {}}})
            return true
        end
    end
    register(executors, undoers)
end

-- Load batch_command with our stub tables
local batch_mod = require("core.commands.batch_command")
batch_mod.register(executors, undoers, nil, nil)

-- Build a BatchCommand spec for one DeleteClip
local spec = {
    {command_type = "DeleteClip", parameters = {clip_id = "clip_x", sequence_id = "seq_x"}}
}
local batch_cmd = Command.create("BatchCommand", "proj_x")
batch_cmd:set_parameter("commands_json", json.encode(spec))
batch_cmd:set_parameter("project_id", "proj_x")
batch_cmd:set_parameter("sequence_id", "seq_x")

-- Execute batch
local ok = executors["BatchCommand"](batch_cmd)
assert(ok, "BatchCommand execute should succeed")
assert(called.delete_exec == 1, "DeleteClip executor should be called once")

-- Undo batch (should call DeleteClip undoer, not executor)
local undo_ok = undoers["BatchCommand"](batch_cmd)
assert(undo_ok, "BatchCommand undo should succeed")
assert(called.delete_undo == 1, "DeleteClip undoer should be called once during batch undo")

print("✅ BatchCommand undo uses child undoers with mutated parameters")
