#!/usr/bin/env luajit

-- Regression: B3 — DeleteClip on already-absent clip must succeed (noop),
-- not crash. This prevents auto-repeat cascading errors.

require("test_env")

print("\n=== B3: DeleteClip already-absent is noop ===")

-- Stub dependencies
local command_helper = require("core.command_helper")
-- Stub functions used by delete_clip
command_helper.restore_clip_state = function() end
command_helper.capture_clip_state = function() return {} end
command_helper.snapshot_properties_for_clip = function() return {} end
command_helper.delete_properties_for_clip = function() end
command_helper.add_delete_mutation = function() end

-- Stub Clip model
package.loaded["models.clip"] = {
    load_optional = function(_id) return nil end,  -- clip doesn't exist
}

-- Load delete_clip
local executors = {}
local undoers = {}
local delete_clip = require("core.commands.delete_clip")
delete_clip.register(executors, undoers, nil, function() end)

-- Create mock command
local Command = require("command")
local cmd = Command.create("DeleteClip", "proj1")
cmd:set_parameter("clip_id", "nonexistent_clip")
cmd:set_parameter("project_id", "proj1")

-- Execute: should return true (noop), not error
local result = executors["DeleteClip"](cmd)
assert(result == true,
    string.format("DeleteClip on absent clip should return true (noop), got %s", tostring(result)))

print("✅ test_delete_already_absent.lua passed")
