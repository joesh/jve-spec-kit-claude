require('test_env')

-- Tests that JKL commands dispatch via TOML keybindings through the registry.
-- Uses LITERAL Qt key codes to catch wrong-constant bugs.

print("=== Test JKL Registry Integration ===")

-- Track command_manager.execute_ui calls
local executed_commands = {}

local mock_command_manager = {
    execute_ui = function(command_name, params)
        executed_commands[#executed_commands + 1] = {
            command = command_name,
            params = params or {},
        }
        return { success = true }
    end,
    get_executor = function(command_name)
        local known = {
            ShuttleForward = true, ShuttleReverse = true,
            ShuttleStop = true, TogglePlay = true,
        }
        if known[command_name] then return function() end end
        return nil
    end,
}

-- Load registry fresh
package.loaded["core.keyboard_shortcut_registry"] = nil
local registry = require("core.keyboard_shortcut_registry")
registry.set_command_manager(mock_command_manager)
registry.load_keybindings("../keymaps/default.jvekeys")

-- ── Literal Qt key codes ──
local QT_KEY_J     = 74
local QT_KEY_K     = 75
local QT_KEY_L     = 76
local QT_KEY_SPACE = 32

-- Helper: find first binding with given command name in array
local function find_binding(combo, cmd_name)
    local bindings = registry.keybindings[combo]
    if not bindings then return nil end
    for _, b in ipairs(bindings) do
        if b.command_name == cmd_name then return b end
    end
    return nil
end

print("\n--- Test 1: TOML has JKL bindings loaded ---")
do
    local j_combo = string.format("%d_%d", QT_KEY_J, 0)
    local k_combo = string.format("%d_%d", QT_KEY_K, 0)
    local l_combo = string.format("%d_%d", QT_KEY_L, 0)

    assert(registry.keybindings[j_combo], "J binding should be loaded at combo " .. j_combo)
    assert(find_binding(j_combo, "ShuttleReverse"),
        "J should map to ShuttleReverse")
    print("  ✓ J → ShuttleReverse")

    assert(registry.keybindings[k_combo], "K binding should be loaded at combo " .. k_combo)
    assert(find_binding(k_combo, "ShuttleStop"),
        "K should map to ShuttleStop")
    print("  ✓ K → ShuttleStop")

    assert(registry.keybindings[l_combo], "L binding should be loaded at combo " .. l_combo)
    assert(find_binding(l_combo, "ShuttleForward"),
        "L should map to ShuttleForward")
    print("  ✓ L → ShuttleForward")
end

print("\n--- Test 2: JKL contexts include timeline + monitors ---")
do
    local l_combo = string.format("%d_%d", QT_KEY_L, 0)
    local binding = find_binding(l_combo, "ShuttleForward")
    assert(binding, "ShuttleForward binding should exist")
    local contexts = binding.contexts
    assert(type(contexts) == "table", "contexts should be a table")

    local has = {}
    for _, ctx in ipairs(contexts) do has[ctx] = true end
    assert(has["timeline"], "ShuttleForward should have timeline context")
    assert(has["source_monitor"], "ShuttleForward should have source_monitor context")
    assert(has["timeline_monitor"], "ShuttleForward should have timeline_monitor context")
    print("  ✓ ShuttleForward contexts: timeline, source_monitor, timeline_monitor")
end

print("\n--- Test 3: handle_key_event dispatches JKL to execute_ui ---")
do
    executed_commands = {}
    local result = registry.handle_key_event(QT_KEY_L, 0, "timeline")
    assert(result == true, "L should be handled")
    assert(#executed_commands == 1, "should have 1 execute_ui call")
    assert(executed_commands[1].command == "ShuttleForward",
        "L should dispatch ShuttleForward, got: " .. tostring(executed_commands[1].command))
    print("  ✓ L in timeline → execute_ui(ShuttleForward)")

    executed_commands = {}
    result = registry.handle_key_event(QT_KEY_J, 0, "source_monitor")
    assert(result == true, "J should be handled")
    assert(executed_commands[1].command == "ShuttleReverse",
        "J should dispatch ShuttleReverse")
    print("  ✓ J in source_monitor → execute_ui(ShuttleReverse)")

    executed_commands = {}
    result = registry.handle_key_event(QT_KEY_K, 0, "timeline_monitor")
    assert(result == true, "K should be handled")
    assert(executed_commands[1].command == "ShuttleStop",
        "K should dispatch ShuttleStop")
    print("  ✓ K in timeline_monitor → execute_ui(ShuttleStop)")
end

print("\n--- Test 4: JKL rejected in wrong context ---")
do
    executed_commands = {}
    local result = registry.handle_key_event(QT_KEY_L, 0, "project_browser")
    assert(result == false, "L should not fire in project_browser context")
    assert(#executed_commands == 0, "no commands should execute in wrong context")
    print("  ✓ L in project_browser → not dispatched")
end

print("\n--- Test 5: Space dispatches TogglePlay ---")
do
    executed_commands = {}
    local result = registry.handle_key_event(QT_KEY_SPACE, 0, "timeline")
    assert(result == true, "Space should be handled")
    assert(executed_commands[1].command == "TogglePlay",
        "Space should dispatch TogglePlay, got: " .. tostring(executed_commands[1].command))
    print("  ✓ Space in timeline → execute_ui(TogglePlay)")
end

print("\n✅ test_jkl_registry_integration.lua passed")
