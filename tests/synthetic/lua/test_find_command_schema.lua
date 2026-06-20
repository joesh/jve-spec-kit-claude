#!/usr/bin/env luajit

-- The find dialog is a pure view: every action dispatches a command carrying
-- the user's query packet (column / operator / value, plus replace_value for
-- the replace actions). Schema validation must accept that packet — otherwise
-- Find Next / Prev / Select-All / Replace throw "unknown param 'value'" the
-- moment the user clicks a button or presses Cmd+G.
--
-- Black-box contract: whatever keys find_dialog puts on the wire, the
-- corresponding command's registered spec must allow.

require('test_env')

local command_schema = require("core.command_schema")
local find_clips = require("core.commands.find_clips")

-- Register to obtain the per-command specs the command_manager will use.
local specs = find_clips.register({}, {}, nil, function() end)

-- The exact packets find_dialog dispatches (find_dialog.lua: get_query_args /
-- do_* button handlers). All values are widget text → strings.
local QUERY = { column = "name", operator = "contains", value = "INT" }
local REPLACE = { column = "name", operator = "contains", value = "INT", replace_value = "EXT" }

local DISPATCHES = {
    { cmd = "Find",               packet = QUERY },
    { cmd = "FindNext",           packet = QUERY },
    { cmd = "FindPrevious",       packet = QUERY },
    { cmd = "SelectAllMatches",   packet = QUERY },
    { cmd = "FindReplaceCurrent", packet = REPLACE },
    { cmd = "FindReplaceAll",     packet = REPLACE },
}

print("=== Find Command Schema Tests ===")

local failed = 0
for _, d in ipairs(DISPATCHES) do
    local entry = specs[d.cmd]
    assert(entry and entry.spec, "no registered spec for " .. d.cmd)

    local ok, _, err = command_schema.validate_and_normalize(
        d.cmd, entry.spec, d.packet,
        { apply_defaults = false, asserts_enabled = false }
    )

    if ok then
        print(string.format("  OK   %s accepts query packet", d.cmd))
    else
        print(string.format("  FAIL %s: %s", d.cmd, tostring(err)))
        failed = failed + 1
    end
end

assert(failed == 0, string.format("%d find command(s) reject the dialog's query packet", failed))

print("✅ test_find_command_schema.lua passed")
