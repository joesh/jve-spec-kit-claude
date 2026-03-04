#!/usr/bin/env luajit

-- Keyboard shortcut registry behavioural tests.

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua"

local registry = require("core.keyboard_shortcut_registry")

local function fail(label, message)
    io.stderr:write(string.format("%s: %s\n", label, message or "failed"))
    os.exit(1)
end

local function assert_true(label, condition)
    if not condition then
        fail(label, "expected truthy")
    end
end

local function assert_equals(label, actual, expected)
    if actual ~= expected then
        fail(label, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
    end
end

local function reset_registry_state()
    registry.commands = {}
    registry.keybindings = {}
    registry.presets = {}
    registry.current_preset = "Default"
    registry.loaded_toml_path = nil
end

local function expect_error(label, fn)
    local ok, err = pcall(fn)
    if ok then
        fail(label, "expected error")
    end
    assert_true(label .. " error type", type(err) == "string" or type(err) == "table")
end

local function test_register_command_contract()
    reset_registry_state()

    expect_error("missing category", function()
        registry.register_command({
            id = "test.no_category",
            name = "No Category",
            description = "missing category",
        })
    end)

    registry.register_command({
        id = "test.valid",
        category = "Testing",
        name = "Valid Command",
        description = "well formed",
    })

    expect_error("duplicate command id", function()
        registry.register_command({
            id = "test.valid",
            category = "Testing",
            name = "Duplicate Command",
            description = "should fail",
        })
    end)
end

local function test_assign_shortcut_conflicts()
    reset_registry_state()

    registry.register_command({
        id = "test.first",
        category = "Testing",
        name = "First",
        description = "",
    })

    registry.register_command({
        id = "test.second",
        category = "Testing",
        name = "Second",
        description = "",
    })

    -- Assign Cmd+L to first
    local ok1, err1 = registry.assign_shortcut("test.first", "Cmd+L")
    assert_true("first assign succeeds", ok1)
    assert_true("first assign no error", err1 == nil)

    -- Conflict: try to assign same key to second
    local ok2, err2 = registry.assign_shortcut("test.second", "Cmd+L")
    assert_true("conflict flagged", not ok2)
    assert_true("conflict message", err2:match("already assigned"))

    -- Verify keybindings has the first command
    local parsed = registry.parse_shortcut("Cmd+L")
    local combo_key = string.format("%d_%d", parsed.key, parsed.modifiers)
    assert_true("keybindings array exists", registry.keybindings[combo_key] ~= nil)
    assert_equals("keybindings has first command", registry.keybindings[combo_key][1].command_name, "test.first")
end

local function test_assign_and_remove_shortcut()
    reset_registry_state()

    registry.register_command({
        id = "test.alpha",
        category = "Testing",
        name = "Alpha",
        description = "",
    })

    -- Assign
    local ok = registry.assign_shortcut("test.alpha", "Cmd+A")
    assert_true("assign succeeds", ok)

    local alpha = registry.commands["test.alpha"]
    assert_equals("alpha shortcut assigned", alpha.current_shortcuts[1].string, "Cmd+A")

    -- Verify it's in keybindings
    local parsed = registry.parse_shortcut("Cmd+A")
    local conflict = registry.find_conflict(parsed.key, parsed.modifiers)
    assert_equals("find_conflict returns alpha", conflict, "test.alpha")

    -- Remove
    registry.remove_shortcut("test.alpha", "Cmd+A")
    local conflict2 = registry.find_conflict(parsed.key, parsed.modifiers)
    assert_equals("alpha shortcut removed from keybindings", conflict2, nil)
    assert_equals("alpha current_shortcuts empty", #alpha.current_shortcuts, 0)
end

local function test_reset_to_defaults_reloads_toml()
    reset_registry_state()

    -- Load from actual TOML file
    local keymap_path = "../keymaps/default.jvekeys"
    registry.load_keybindings(keymap_path)

    -- Verify something loaded
    local count = 0
    for _ in pairs(registry.keybindings) do count = count + 1 end
    assert_true("keybindings loaded", count > 0)

    -- Remember the count
    local original_count = count

    -- Clear keybindings manually
    registry.keybindings = {}

    -- Reset should reload from stored path
    registry.reset_to_defaults()

    -- Verify reloaded
    local count2 = 0
    for _ in pairs(registry.keybindings) do count2 = count2 + 1 end
    assert_equals("reset restored keybinding count", count2, original_count)
end

local tests = {
    test_register_command_contract,
    test_assign_shortcut_conflicts,
    test_assign_and_remove_shortcut,
    test_reset_to_defaults_reloads_toml,
}

for index, test in ipairs(tests) do
    test()
    io.stdout:write(string.format("  ✅ test %d passed\n", index))
end

print("✅ test_keyboard_shortcut_registry.lua passed")
os.exit(0)
