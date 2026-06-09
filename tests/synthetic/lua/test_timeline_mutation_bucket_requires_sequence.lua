#!/usr/bin/env luajit

-- Regression: mutation bucket must assert if sequence_id is missing.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local command_helper = require("core.command_helper")

local fake_cmd = {type = "TestCommand", parameters = {}, set_parameter = function() end, get_parameter = function() end}

local ok, err = pcall(function()
    command_helper.add_update_mutation(fake_cmd, nil, {clip_id = "c", track_id = "t"})
end)

assert(ok == false, "expected mutation bucket to assert when sequence_id is missing")
assert(tostring(err):find("Missing sequence_id"), "error should mention missing sequence_id")

print("✅ Mutation bucket asserts on missing sequence_id")
