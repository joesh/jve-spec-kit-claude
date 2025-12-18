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
    registry.active_shortcuts = {}
    registry.presets = {}
    registry.current_preset = "Default"
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
            default_shortcuts = {}
        })
    end)

    registry.register_command({
        id = "test.valid",
        category = "Testing",
        name = "Valid Command",
        description = "well formed",
        default_shortcuts = {"Cmd+Alt+V"}
    })

    expect_error("duplicate command id", function()
        registry.register_command({
            id = "test.valid",
            category = "Testing",
            name = "Duplicate Command",
            description = "should fail",
            default_shortcuts = {}
        })
    end)

    local defaults = {"Cmd+Shift+D"}
    registry.register_command({
        id = "test.copy_defaults",
        category = "Testing",
        name = "Copy Defaults",
        description = "",
        default_shortcuts = defaults
    })

    defaults[1] = "Modified"
    local stored = registry.commands["test.copy_defaults"].default_shortcuts[1]
    assert_equals("default table copied", stored, "Cmd+Shift+D")
end

local function test_assign_shortcut_conflicts()
    reset_registry_state()

    registry.register_command({
        id = "test.first",
        category = "Testing",
        name = "First",
        description = "",
        default_shortcuts = {"Cmd+L"}
    })

    registry.register_command({
        id = "test.second",
        category = "Testing",
        name = "Second",
        description = "",
        default_shortcuts = {}
    })

    registry.reset_to_defaults()

    local ok, err = registry.assign_shortcut("test.second", "Cmd+L")
    assert_true("conflict flagged", not ok)
    assert_true("conflict message", err:match("already assigned"))
end

local function test_reset_to_defaults_assigns_shortcuts()
    reset_registry_state()

    registry.register_command({
        id = "test.alpha",
        category = "Testing",
        name = "Alpha",
        description = "",
        default_shortcuts = {"Cmd+A"}
    })

    registry.register_command({
        id = "test.bravo",
        category = "Testing",
        name = "Bravo",
        description = "",
        default_shortcuts = {"Cmd+B"}
    })

    registry.reset_to_defaults()

    local alpha = registry.commands["test.alpha"]
    local bravo = registry.commands["test.bravo"]

    assert_equals("alpha shortcut assigned", alpha.current_shortcuts[1].string, "Cmd+A")
    assert_equals("bravo shortcut assigned", bravo.current_shortcuts[1].string, "Cmd+B")

    -- Removing a shortcut should clear active map entries.
    local parsed, parse_err = registry.parse_shortcut("Cmd+A")
    assert_true("parse shortcut", parsed ~= nil and parse_err == nil)
    registry.remove_shortcut("test.alpha", "Cmd+A")
    local conflict = registry.find_conflict(parsed.key, parsed.modifiers)
    assert_equals("alpha shortcut removed", conflict, nil)
end

local tests = {
    test_register_command_contract,
    test_assign_shortcut_conflicts,
    test_reset_to_defaults_assigns_shortcuts
}

for index, test in ipairs(tests) do
    test()
    io.stdout:write(string.format("✅ test %d passed\n", index))
end

os.exit(0)
