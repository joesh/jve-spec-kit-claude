#!/usr/bin/env luajit

-- Tests that TOML keybinding dispatch fails loudly (never silently drops).
--
-- Covers:
-- 1. Binding found, command not registered → must assert (not silent drop)
-- 2. Binding found, command_manager not set → must assert
-- 3. Binding found, command registered → dispatches successfully

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua"

local registry = require("core.keyboard_shortcut_registry")
require("core.keyboard_constants") -- loaded by registry.parse_shortcut

local function fail(label, message)
    io.stderr:write(string.format("FAIL %s: %s\n", label, message or "failed"))
    os.exit(1)
end

local function assert_equals(label, actual, expected)
    if actual ~= expected then
        fail(label, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
    end
end

local function assert_true(label, condition)
    if not condition then fail(label, "expected truthy") end
end

local function expect_error(label, fn)
    local ok, err = pcall(fn)
    if ok then
        fail(label, "expected error but call succeeded silently")
    end
    return err
end

local function reset()
    registry.keybindings = {}
    registry.commands = {}
    registry.active_shortcuts = {}
end

-- Inject a binding directly (bypasses TOML file loading)
local function inject_binding(key_combo_str, command_name, positional_args, contexts)
    local shortcut = assert(registry.parse_shortcut(key_combo_str))
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {
        command_name = command_name,
        positional_args = positional_args or {},
        named_params = {},
        contexts = contexts or {},
        shortcut = shortcut,
        category = "Test",
    }
    return shortcut
end

--------------------------------------------------------------------------------
-- Test 1: Binding found, command NOT registered → must error (not silent drop)
--------------------------------------------------------------------------------
local function test_unregistered_command_asserts()
    reset()

    -- Mock command_manager where get_executor returns nil
    registry.set_command_manager({
        get_executor = function() return nil end,
        execute_ui = function() error("should not be called") end,
    })

    inject_binding("Cmd+3", "SelectPanel", {"timeline"})

    local shortcut = registry.parse_shortcut("Cmd+3")
    expect_error("unregistered command must assert",
        function()
            registry.handle_key_event(shortcut.key, shortcut.modifiers, "global")
        end)
end

--------------------------------------------------------------------------------
-- Test 2: command_manager not set → must error (not silent drop)
--------------------------------------------------------------------------------
local function test_nil_command_manager_asserts()
    reset()

    registry.set_command_manager(nil)
    inject_binding("Cmd+4", "SelectPanel", {"project_browser"})

    local shortcut = registry.parse_shortcut("Cmd+4")
    expect_error("nil command_manager must assert",
        function()
            registry.handle_key_event(shortcut.key, shortcut.modifiers, "global")
        end)
end

--------------------------------------------------------------------------------
-- Test 3: Binding found, command registered → dispatches successfully
--------------------------------------------------------------------------------
local function test_registered_command_dispatches()
    reset()

    local dispatched_name = nil
    local dispatched_params = nil

    registry.set_command_manager({
        get_executor = function() return function() end end,
        execute_ui = function(name, params)
            dispatched_name = name
            dispatched_params = params
            return { success = true }
        end,
    })

    inject_binding("Cmd+3", "SelectPanel", {"timeline"})

    local shortcut = registry.parse_shortcut("Cmd+3")
    local handled = registry.handle_key_event(shortcut.key, shortcut.modifiers, "global")

    assert_true("handle_key_event returned true", handled)
    assert_equals("dispatched command name", dispatched_name, "SelectPanel")
    assert_true("positional args passed", dispatched_params._positional ~= nil)
    assert_equals("panel arg", dispatched_params._positional[1], "timeline")
end

--------------------------------------------------------------------------------
-- Test 4: Context mismatch → returns false (legitimate non-dispatch)
--------------------------------------------------------------------------------
local function test_context_mismatch_returns_false()
    reset()

    registry.set_command_manager({
        get_executor = function() return function() end end,
        execute_ui = function() error("should not dispatch in wrong context") end,
    })

    inject_binding("Cmd+3", "SelectPanel", {"timeline"}, {"@timeline"})

    local shortcut = registry.parse_shortcut("Cmd+3")
    -- Context is "project_browser" but binding requires "@timeline"
    local handled = registry.handle_key_event(shortcut.key, shortcut.modifiers, "project_browser")
    assert_true("context mismatch returns false", handled == false)
end

--------------------------------------------------------------------------------
-- Test 5: parse_shortcut modifier mapping matches Qt's macOS convention
-- Qt swaps Control/Meta on macOS: Command key = ControlModifier (0x04000000)
--------------------------------------------------------------------------------
local function test_cmd_modifier_matches_qt()
    local kb = require("core.keyboard_constants")
    local MOD = kb.MOD

    -- "Cmd+3" must produce ControlModifier (what Qt sends for Command key)
    -- NOT MetaModifier (what Qt sends for physical Control key on macOS)
    local shortcut = assert(registry.parse_shortcut("Cmd+3"))
    assert_equals("Cmd+3 key code", shortcut.key, 51) -- '3' = 51
    assert_equals("Cmd modifier = ControlModifier (Qt Command)",
        shortcut.modifiers, MOD.Control)

    -- "Ctrl" on macOS should produce MetaModifier (physical Control key)
    -- On Linux/Windows, Ctrl = ControlModifier
    local ctrl_shortcut = assert(registry.parse_shortcut("Ctrl+A"))
    if jit.os == "OSX" then
        assert_equals("Ctrl on macOS = MetaModifier (physical Control key)",
            ctrl_shortcut.modifiers, MOD.Meta)
    else
        assert_equals("Ctrl on Linux/Windows = ControlModifier",
            ctrl_shortcut.modifiers, MOD.Control)
    end
end

--------------------------------------------------------------------------------

local tests = {
    {"unregistered command asserts", test_unregistered_command_asserts},
    {"nil command_manager asserts", test_nil_command_manager_asserts},
    {"registered command dispatches", test_registered_command_dispatches},
    {"context mismatch returns false", test_context_mismatch_returns_false},
    {"Cmd modifier matches Qt convention", test_cmd_modifier_matches_qt},
}

for _, t in ipairs(tests) do
    t[2]()
    print(string.format("  ✅ %s", t[1]))
end

print("✅ test_keybinding_dispatch_failfast.lua passed")
