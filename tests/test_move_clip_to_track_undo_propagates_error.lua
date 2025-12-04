#!/usr/bin/env luajit

-- Regression: MoveClipToTrack undo should surface revert errors (not silent failures).

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path

require("test_env")

local command_helper = require("core.command_helper")
local move_mod = require("core.commands.move_clip_to_track")

-- Stub command and db
local fake_db = {
    begin_transaction = function() return true end,
    rollback_transaction = function() end
}

local fake_cmd = {
    type = "MoveClipToTrack",
    parameters = {},
    get_parameter = function(self, k) return self.parameters[k] end,
    set_parameter = function(self, k, v) self.parameters[k] = v end,
}

fake_cmd:set_parameter("executed_mutations", {{type="update"}})
fake_cmd:set_parameter("sequence_id", "seq-1")

-- Monkey-patch revert_mutations to force a failure
local original_revert = command_helper.revert_mutations
command_helper.revert_mutations = function() return false, "forced-revert-fail" end

local executors, undoers = {}, {}
move_mod.register(executors, undoers, fake_db, function() end)

local undoer = undoers["MoveClipToTrack"]
assert(type(undoer) == "function", "missing undoer")

local result = undoer(fake_cmd)
local res_table = type(result) == "table" and result or {success = result}
assert(res_table.success == false, "undoer should return failure on revert error")
local errmsg = tostring(res_table.error_message or res_table[2] or "")
assert(errmsg:match("forced%-revert%-fail"), "error message should include revert failure: " .. errmsg)

-- Restore patch
command_helper.revert_mutations = original_revert

print("✅ MoveClipToTrack undo surfaces revert errors")
