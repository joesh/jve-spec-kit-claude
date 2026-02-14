require('test_env')

-- Tests that JKL commands dispatch via TOML keybindings through the registry.
-- After the keyboard dispatch refactor, JKL bindings live in default.jvekeys
-- and dispatch through shortcut_registry → command_manager.execute_ui().

print("=== Test JKL Registry Integration ===")

-- Track command_manager.execute_ui calls
local executed_commands = {}

-- Mock command_manager
local mock_command_manager = {
    execute_ui = function(command_name, params)
        executed_commands[#executed_commands + 1] = {
            command = command_name,
            params = params or {},
        }
        return { success = true }
    end,
    get_executor = function(command_name)
        -- Pretend all playback commands are registered
        local known = {
            ShuttleForward = true, ShuttleReverse = true,
            ShuttleStop = true, TogglePlay = true,
        }
        if known[command_name] then return function() end end
        return nil
    end,
}

-- Load registry fresh (not mocked — we want to test the real loader)
package.loaded["core.keyboard_shortcut_registry"] = nil
local registry = require("core.keyboard_shortcut_registry")
registry.set_command_manager(mock_command_manager)

-- Load TOML keybindings
registry.load_keybindings("../keymaps/default.jvekeys")

-- KEY constants for J/K/L/Space
local kb = require("core.keyboard_constants")
local KEY = kb.KEY

print("\n--- Test 1: TOML has JKL bindings loaded ---")
do
    -- J = ShuttleReverse, K = ShuttleStop, L = ShuttleForward
    local j_combo = string.format("%d_%d", KEY.J, 0)
    local k_combo = string.format("%d_%d", KEY.K, 0)
    local l_combo = string.format("%d_%d", KEY.L, 0)

    assert(registry.keybindings[j_combo], "J binding should be loaded")
    assert(registry.keybindings[j_combo].command_name == "ShuttleReverse",
        "J should map to ShuttleReverse, got: " .. tostring(registry.keybindings[j_combo].command_name))
    print("  ✓ J → ShuttleReverse")

    assert(registry.keybindings[k_combo], "K binding should be loaded")
    assert(registry.keybindings[k_combo].command_name == "ShuttleStop",
        "K should map to ShuttleStop, got: " .. tostring(registry.keybindings[k_combo].command_name))
    print("  ✓ K → ShuttleStop")

    assert(registry.keybindings[l_combo], "L binding should be loaded")
    assert(registry.keybindings[l_combo].command_name == "ShuttleForward",
        "L should map to ShuttleForward, got: " .. tostring(registry.keybindings[l_combo].command_name))
    print("  ✓ L → ShuttleForward")
end

print("\n--- Test 2: JKL contexts include timeline + monitors ---")
do
    local l_combo = string.format("%d_%d", KEY.L, 0)
    local contexts = registry.keybindings[l_combo].contexts
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

    -- L in timeline context → ShuttleForward
    local result = registry.handle_key_event(KEY.L, 0, "timeline")
    assert(result == true, "L should be handled")
    assert(#executed_commands == 1, "should have 1 execute_ui call")
    assert(executed_commands[1].command == "ShuttleForward",
        "L should dispatch ShuttleForward, got: " .. tostring(executed_commands[1].command))
    print("  ✓ L in timeline → execute_ui(ShuttleForward)")

    executed_commands = {}

    -- J in source_monitor context → ShuttleReverse
    result = registry.handle_key_event(KEY.J, 0, "source_monitor")
    assert(result == true, "J should be handled")
    assert(executed_commands[1].command == "ShuttleReverse",
        "J should dispatch ShuttleReverse")
    print("  ✓ J in source_monitor → execute_ui(ShuttleReverse)")

    executed_commands = {}

    -- K in timeline_monitor → ShuttleStop
    result = registry.handle_key_event(KEY.K, 0, "timeline_monitor")
    assert(result == true, "K should be handled")
    assert(executed_commands[1].command == "ShuttleStop",
        "K should dispatch ShuttleStop")
    print("  ✓ K in timeline_monitor → execute_ui(ShuttleStop)")
end

print("\n--- Test 4: JKL rejected in wrong context ---")
do
    executed_commands = {}

    -- L in project_browser → should not fire (no project_browser context)
    local result = registry.handle_key_event(KEY.L, 0, "project_browser")
    assert(result == false, "L should not fire in project_browser context")
    assert(#executed_commands == 0, "no commands should execute in wrong context")
    print("  ✓ L in project_browser → not dispatched")
end

print("\n--- Test 5: Space dispatches TogglePlay ---")
do
    executed_commands = {}

    local result = registry.handle_key_event(KEY.Space, 0, "timeline")
    assert(result == true, "Space should be handled")
    assert(executed_commands[1].command == "TogglePlay",
        "Space should dispatch TogglePlay, got: " .. tostring(executed_commands[1].command))
    print("  ✓ Space in timeline → execute_ui(TogglePlay)")
end

print("\n✅ test_jkl_registry_integration.lua passed")
