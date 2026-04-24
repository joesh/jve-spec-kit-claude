#!/usr/bin/env luajit
-- Regression test: TOML-bound commands that have no menus.xml entry are
-- auto-registered as stubs by load_keybindings, so the keyboard-customization
-- dialog's picture lookup never asserts on "binding references unregistered
-- command 'X'".
--
-- Reproducer: TSO 2026-04-20 10:57:02 — F2 is bound to StartRename in
-- default.jvekeys, StartRename is NOT in menus.xml, so registry.commands
-- never gained an entry. Opening the customization dialog walked all
-- bindings, hit StartRename, and asserted in keyboard_picture.lua:170.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local registry = require("core.keyboard_shortcut_registry")

-- Minimal TOML file with a binding to an unregistered command.
local tmp = "/tmp/jve/test_toml_autoregister.jvekeys"
os.execute("mkdir -p /tmp/jve")
do
    local f = assert(io.open(tmp, "w"), "cannot write " .. tmp)
    f:write([[
["Project Browser"]
"F2" = "CommandWithoutMenu @project_browser"
"Cmd+Shift+X" = "AnotherOrphanCommand"
]])
    f:close()
end

-- Ensure the commands under test don't exist before load.
registry.commands["CommandWithoutMenu"] = nil
registry.commands["AnotherOrphanCommand"] = nil

registry.load_keybindings(tmp)

local pass, fail = 0, 0
local function check(label, ok) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end end

print("=== keyboard_shortcut_registry: auto-register TOML-only commands ===\n")

local cmd = registry.commands["CommandWithoutMenu"]
check("stub entry exists for TOML-only command",              cmd ~= nil)
check("stub.id matches command_name",                         cmd and cmd.id == "CommandWithoutMenu")
check("stub.name matches command_name (fallback label)",      cmd and cmd.name == "CommandWithoutMenu")
check("stub.category comes from TOML section",                cmd and cmd.category == "Project Browser")
check("stub.description is empty string (not nil)",           cmd and cmd.description == "")
check("stub.current_shortcuts is empty table",                cmd and type(cmd.current_shortcuts) == "table")

local cmd2 = registry.commands["AnotherOrphanCommand"]
check("second TOML-only command also auto-registered", cmd2 ~= nil)

-- If the command is ALREADY registered (e.g., via menus.xml), load_keybindings
-- must NOT overwrite its richer metadata with a stub.
registry.commands["CommandWithoutMenu"] = nil
registry.register_command({
    id = "PreRegistered",
    category = "Edit",
    name = "Pre-registered Command",
    description = "From menus.xml",
})
do
    local f = assert(io.open(tmp, "w"))
    f:write([[
["Edit"]
"Cmd+Shift+P" = "PreRegistered"
]])
    f:close()
end
registry.load_keybindings(tmp)
local cmd3 = registry.commands["PreRegistered"]
check("menu-registered command not overwritten: name preserved",
    cmd3 and cmd3.name == "Pre-registered Command")
check("menu-registered command not overwritten: description preserved",
    cmd3 and cmd3.description == "From menus.xml")

-- Clean up.
registry.commands["CommandWithoutMenu"] = nil
registry.commands["AnotherOrphanCommand"] = nil
registry.commands["PreRegistered"] = nil
os.remove(tmp)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_keyboard_registry_toml_autoregister.lua passed")
