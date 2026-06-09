#!/usr/bin/env luajit
--- Regression: keymaps/default.jvekeys MUST parse cleanly via tinytoml.
---
--- Background: 019 needed source_monitor I/O bound to a different command
--- (SetMarkAndTrimIfClip) than the timeline I/O (SetMark). An initial
--- patch added duplicate "I"/"O" keys under [Marks] — TOML disallows
--- duplicate keys in a table, so tinytoml's `Cannot override previously
--- defined key` assertion failed the entire parse and EVERY keybinding
--- went silently un-registered (E, Comma, Period, etc. all dead).
---
--- This test pins: the parse succeeds AND a representative sample of
--- bindings end up in load_keybindings's registry.

require("test_env")

local registry = require("core.keyboard_shortcut_registry")

print("=== test_default_keymap_loads.lua ===")

local keymap_path = require("test_env").resolve_repo_path("keymaps/default.jvekeys")

-- Bare TOML parse — must not raise.
do
    local f = assert(io.open(keymap_path, "r"))
    local content = f:read("*all"); f:close()
    local tinytoml = require("tinytoml")
    local ok, data_or_err = pcall(tinytoml.parse, content, { load_from_string = true })
    assert(ok, "default.jvekeys must parse: " .. tostring(data_or_err))
    assert(type(data_or_err) == "table", "parse returned non-table")
    print("  ✓ tinytoml parses default.jvekeys cleanly")
end

-- load_keybindings must populate M.keybindings.
registry.load_keybindings(keymap_path)

-- Sample bindings that 2026-05-20's TSO showed as silently broken when
-- the duplicate-I parse failure killed the file.
local function find_binding(combo)
    local shortcut = registry.parse_shortcut(combo)
    assert(shortcut, "parse_shortcut: bad combo " .. combo)
    local key = shortcut.key .. "_" .. shortcut.modifiers
    return registry.keybindings[key]
end

local function assert_bound_to(combo, expected_command)
    local entries = find_binding(combo)
    assert(entries, string.format("%s: no binding registered", combo))
    assert(#entries >= 1, string.format("%s: empty binding list", combo))
    for _, b in ipairs(entries) do
        if b.command_name == expected_command then
            print(string.format("  ✓ %s → %s", combo, expected_command))
            return
        end
    end
    error(string.format("%s: expected binding to %s; got %s",
        combo, expected_command, entries[1].command_name))
end

assert_bound_to("E",      "ExtendEdit")
assert_bound_to("Comma",  "NudgeSelection")
assert_bound_to("Period", "NudgeSelection")
assert_bound_to("I",      "SetMark")  -- timeline-scope binding still there
assert_bound_to("O",      "SetMark")

-- 019: source-monitor variant lives under its own scope, separate command.
do
    local entries = find_binding("I")
    local saw_set_mark_and_trim = false
    for _, b in ipairs(entries) do
        if b.command_name == "SetMarkAndTrimIfClip" then saw_set_mark_and_trim = true; break end
    end
    assert(saw_set_mark_and_trim,
        "I must ALSO have a SetMarkAndTrimIfClip binding (source_monitor scope)")
    print("  ✓ I has SetMarkAndTrimIfClip binding for @source_monitor")
end

print("\n✅ test_default_keymap_loads.lua passed")
