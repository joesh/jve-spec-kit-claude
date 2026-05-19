#!/usr/bin/env luajit

-- NSF: command_registry's SPEC.keyboard auto-register hook asserted on
-- missing `category` and `display_name` but accepted a missing `description`
-- by falling back to "". A keyboard-bindable command without a description
-- ends up in the dialog as an unlabelled row — a silent failure to surface
-- WHY the user might want to bind it. NSF half-1: required metadata must be
-- present, not silently substituted with empty string.

require("test_env")

print("=== test_nsf_keyboard_metadata_strict.lua ===")

local database         = require("core.database")
local command_registry = require("core.command_registry")
local registry         = require("core.keyboard_shortcut_registry")

local DB = "/tmp/jve/test_nsf_keyboard_metadata.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
command_registry.init(database.get_connection(), function() end)
for k in pairs(registry.commands) do registry.commands[k] = nil end

-- Register a synthetic command with INCOMPLETE keyboard metadata. The
-- expected behaviour is a loud assert at register time, surfacing the
-- offending command and the missing field.
local ok, err = pcall(function()
    command_registry.register_executor("TestNSFKbMissingDesc",
        function() return true end,
        nil,
        {
            undoable = false,
            keyboard = {
                category     = "Test ▸ NSF",
                display_name = "Test Cmd",
                -- description intentionally omitted
            },
            args = {},
        })
end)
assert(not ok, "FAIL: missing keyboard.description must assert at register time, "
    .. "not silently fall back to \"\".")
assert(type(err) == "string" and err:find("description"),
    "FAIL: assert error must mention which field is missing; got: " .. tostring(err))

-- Empty string is also unacceptable — same reason.
local ok2, err2 = pcall(function()
    command_registry.register_executor("TestNSFKbEmptyDesc",
        function() return true end,
        nil,
        {
            undoable = false,
            keyboard = {
                category     = "Test ▸ NSF",
                display_name = "Test Cmd",
                description  = "",
            },
            args = {},
        })
end)
assert(not ok2,
    "FAIL: empty keyboard.description must be rejected — a blank dialog row "
    .. "hides the command's purpose from the user.")
assert(type(err2) == "string" and err2:find("description"),
    "FAIL: empty-description error must mention which field; got: " .. tostring(err2))

-- Sanity: a complete keyboard table registers without complaint.
local ok3 = pcall(function()
    command_registry.register_executor("TestNSFKbOK",
        function() return true end,
        nil,
        {
            undoable = false,
            keyboard = {
                category     = "Test ▸ NSF",
                display_name = "Test Cmd",
                description  = "Does the test thing.",
            },
            args = {},
        })
end)
assert(ok3, "complete keyboard metadata must register cleanly")
assert(registry.commands["TestNSFKbOK"], "complete metadata should reach kbsr")

print("  keyboard metadata invariants enforced — OK")
print("\n✅ test_nsf_keyboard_metadata_strict.lua passed")
