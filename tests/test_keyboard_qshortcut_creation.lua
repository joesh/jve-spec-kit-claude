#!/usr/bin/env luajit

-- Test: keyboard_shortcut_registry.create_qt_shortcuts()
-- Verifies QShortcut objects created from TOML bindings with correct:
--   - key sequence (TOML → Qt notation)
--   - context (window vs widget_children)
--   - parent widget (window vs panel container)
--   - handler connection
--   - cleanup/destruction

require("test_env")
local registry = require("core.keyboard_shortcut_registry")

local function fail(label, message)
    io.stderr:write(string.format("FAIL %s: %s\n", label, message or "failed"))
    os.exit(1)
end

local function assert_true(label, condition)
    if not condition then fail(label, "expected truthy") end
end

local function assert_equals(label, actual, expected)
    if actual ~= expected then
        fail(label, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
    end
end

-------------------------------------------------------------------------------
-- Mock C++ bindings
-------------------------------------------------------------------------------

local created_shortcuts = {}
local connected_handlers = {}
local deleted_shortcuts = {}
local mock_id = 0

local function mock_widget(name)
    mock_id = mock_id + 1
    return { _mock_id = mock_id, _name = name or ("widget_" .. mock_id) }
end

-- luacheck: globals qt_create_shortcut qt_connect_shortcut qt_delete_shortcut
qt_create_shortcut = function(parent, key_seq, context)
    local sc = mock_widget("shortcut")
    created_shortcuts[#created_shortcuts + 1] = {
        parent = parent,
        key_seq = key_seq,
        context = context or "window",
        shortcut = sc,
    }
    return sc
end

qt_connect_shortcut = function(shortcut, handler_name)
    connected_handlers[#connected_handlers + 1] = {
        shortcut = shortcut,
        handler_name = handler_name,
    }
end

qt_delete_shortcut = function(shortcut)
    deleted_shortcuts[#deleted_shortcuts + 1] = shortcut
end

-- Mock command_manager for handler invocation test
local executed_commands = {}
local mock_cmd_mgr = {
    execute_ui = function(name, params)
        executed_commands[#executed_commands + 1] = { name = name, params = params }
        return { success = true }
    end,
    get_executor = function() return true end,
    peek_command_event_origin = function() return nil end,
    begin_command_event = function() end,
    end_command_event = function() end,
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local containers

local function reset()
    created_shortcuts = {}
    connected_handlers = {}
    deleted_shortcuts = {}
    executed_commands = {}
    mock_id = 0

    registry.commands = {}
    registry.keybindings = {}
    registry.presets = {}
    registry.current_preset = "Default"
    registry.loaded_toml_path = nil
    registry.active_shortcuts = nil

    registry.set_command_manager(mock_cmd_mgr)

    containers = {
        window = mock_widget("main_window"),
        timeline = mock_widget("timeline_panel"),
        source_monitor = mock_widget("source_monitor"),
        timeline_monitor = mock_widget("timeline_monitor"),
        project_browser = mock_widget("project_browser"),
    }
end

--- Find all created shortcuts matching a key_seq pattern
local function find_shortcuts_by_key(key_seq)
    local matches = {}
    for _, sc in ipairs(created_shortcuts) do
        if sc.key_seq == key_seq then
            matches[#matches + 1] = sc
        end
    end
    return matches
end

--- Find all created shortcuts parented to a specific container
local function find_shortcuts_by_parent(parent)
    local matches = {}
    for _, sc in ipairs(created_shortcuts) do
        if sc.parent == parent then
            matches[#matches + 1] = sc
        end
    end
    return matches
end

-------------------------------------------------------------------------------
-- Tests
-------------------------------------------------------------------------------

local function test_global_shortcut_gets_window_context()
    reset()
    -- Manually add a global binding (no contexts)
    local shortcut = registry.parse_shortcut("Cmd+Q")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "Quit",
        positional_args = {},
        named_params = {},
        contexts = {},
        category = "Application",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    assert_equals("one shortcut created", #created_shortcuts, 1)
    assert_equals("parent is window", created_shortcuts[1].parent, containers.window)
    assert_equals("context is window", created_shortcuts[1].context, "window")
    -- Cmd+Q → Ctrl+Q in Qt notation (Qt Ctrl = macOS Command)
    assert_equals("key_seq is Ctrl+Q", created_shortcuts[1].key_seq, "Ctrl+Q")
    assert_equals("handler connected", #connected_handlers, 1)
end

local function test_panel_scoped_shortcut_gets_widget_children()
    reset()
    local shortcut = registry.parse_shortcut("D")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "ToggleClipEnabled",
        positional_args = {},
        named_params = {},
        contexts = { "timeline" },
        category = "Timeline",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    assert_equals("one shortcut created", #created_shortcuts, 1)
    assert_equals("parent is timeline", created_shortcuts[1].parent, containers.timeline)
    assert_equals("context is widget_children", created_shortcuts[1].context, "widget_children")
    assert_equals("key_seq is D", created_shortcuts[1].key_seq, "D")
end

local function test_multi_context_creates_multiple_shortcuts()
    reset()
    local shortcut = registry.parse_shortcut("Space")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "TogglePlay",
        positional_args = {},
        named_params = {},
        contexts = { "timeline", "source_monitor", "timeline_monitor" },
        category = "Transport",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    assert_equals("three shortcuts created", #created_shortcuts, 3)
    -- Each on different parent
    assert_equals("first parent is timeline", created_shortcuts[1].parent, containers.timeline)
    assert_equals("second parent is source_monitor", created_shortcuts[2].parent, containers.source_monitor)
    assert_equals("third parent is timeline_monitor", created_shortcuts[3].parent, containers.timeline_monitor)
    -- All widget_children context
    for i = 1, 3 do
        assert_equals("context " .. i, created_shortcuts[i].context, "widget_children")
        assert_equals("key_seq " .. i, created_shortcuts[i].key_seq, "Space")
    end
    assert_equals("three handlers connected", #connected_handlers, 3)
end

local function test_modifier_conversion_cmd_to_ctrl()
    reset()
    local shortcut = registry.parse_shortcut("Cmd+Shift+Z")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "Redo",
        positional_args = {},
        named_params = {},
        contexts = {},
        category = "Application",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    assert_equals("key_seq Ctrl+Shift+Z", created_shortcuts[1].key_seq, "Ctrl+Shift+Z")
end

local function test_ctrl_becomes_meta_on_macos()
    reset()
    local shortcut = registry.parse_shortcut("Ctrl+G")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "GoToTimecode",
        positional_args = {},
        named_params = {},
        contexts = { "timeline" },
        category = "Application",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    -- On macOS: physical Control key → Qt Meta modifier
    if jit.os == "OSX" then
        assert_equals("key_seq Meta+G", created_shortcuts[1].key_seq, "Meta+G")
    else
        assert_equals("key_seq Ctrl+G", created_shortcuts[1].key_seq, "Ctrl+G")
    end
end

local function test_symbol_key_conversion()
    reset()
    -- Tilde (shifted symbol) — no Shift modifier in combo_key
    local shortcut = registry.parse_shortcut("Tilde")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "ToggleMaximizePanel",
        positional_args = {},
        named_params = {},
        contexts = {},
        category = "View",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    assert_equals("tilde key_seq", created_shortcuts[1].key_seq, "~")
end

local function test_bracket_key_conversion()
    reset()
    local shortcut = registry.parse_shortcut("Cmd+Shift+BracketLeft")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "TrimHead",
        positional_args = {},
        named_params = {},
        contexts = { "timeline" },
        category = "Timeline",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    -- BracketLeft → [, but Shift+BracketLeft → BraceLeft in parse_shortcut
    -- parse_shortcut promotes Shift+[ to { (BraceLeft, code 123) with no Shift
    -- So the Qt key seq should be Ctrl+{ not Ctrl+Shift+[
    assert_equals("bracket key_seq", created_shortcuts[1].key_seq, "Ctrl+{")
end

local function test_handler_executes_command()
    reset()
    local shortcut = registry.parse_shortcut("N")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "ToggleSnapping",
        positional_args = {},
        named_params = {},
        contexts = { "timeline" },
        category = "Timeline",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    -- Find the handler global and invoke it
    assert_equals("handler connected", #connected_handlers, 1)
    local handler_name = connected_handlers[1].handler_name
    assert_true("handler is global", type(_G[handler_name]) == "function")

    -- Call the handler (simulates QShortcut::activated signal)
    _G[handler_name]()

    assert_equals("one command executed", #executed_commands, 1)
    assert_equals("command name", executed_commands[1].name, "ToggleSnapping")
end

local function test_handler_passes_params()
    reset()
    local shortcut = registry.parse_shortcut("Shift+Delete")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "DeleteSelection",
        positional_args = {},
        named_params = { ripple = true },
        contexts = {},
        category = "Timeline",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    local handler_name = connected_handlers[1].handler_name
    _G[handler_name]()

    assert_equals("command name", executed_commands[1].name, "DeleteSelection")
    assert_equals("ripple param", executed_commands[1].params.ripple, true)
end

local function test_handler_passes_positional_args()
    reset()
    local shortcut = registry.parse_shortcut("I")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "SetMark",
        positional_args = { "in" },
        named_params = {},
        contexts = { "timeline", "source_monitor" },
        category = "Marks",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    -- Two shortcuts created (timeline + source_monitor), both share same command
    assert_equals("two shortcuts", #created_shortcuts, 2)
    -- Invoke first handler
    _G[connected_handlers[1].handler_name]()
    assert_equals("positional arg", executed_commands[1].params._positional[1], "in")
end

local function test_destroy_cleans_up()
    reset()
    local shortcut = registry.parse_shortcut("J")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "ShuttleReverse",
        positional_args = {},
        named_params = {},
        contexts = { "timeline", "source_monitor", "timeline_monitor" },
        category = "Transport",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)
    assert_equals("three created", #created_shortcuts, 3)

    -- Remember handler names before destroy
    local handler_names = {}
    for _, h in ipairs(connected_handlers) do
        handler_names[#handler_names + 1] = h.handler_name
    end

    registry.destroy_qt_shortcuts()

    assert_equals("three deleted", #deleted_shortcuts, 3)
    -- Handlers removed from globals
    for _, name in ipairs(handler_names) do
        assert_true("handler " .. name .. " removed", _G[name] == nil)
    end
end

local function test_full_toml_creates_shortcuts()
    reset()
    -- Load the real TOML file
    registry.load_keybindings("../keymaps/default.jvekeys")
    registry.create_qt_shortcuts(containers)

    -- Verify substantial number created (80+ bindings, many multi-context)
    assert_true("many shortcuts created", #created_shortcuts > 50)
    assert_equals("handlers match shortcuts", #connected_handlers, #created_shortcuts)

    -- Spot-check: Cmd+Z (Undo, global) → Ctrl+Z on window
    local undo = find_shortcuts_by_key("Ctrl+Z")
    assert_true("Ctrl+Z exists", #undo >= 1)
    -- At least one should be global (window parent)
    local found_global = false
    for _, sc in ipairs(undo) do
        if sc.parent == containers.window then found_global = true end
    end
    assert_true("Ctrl+Z has window parent", found_global)

    -- Spot-check: Space (TogglePlay, 3 contexts) → 3 shortcuts
    local space = find_shortcuts_by_key("Space")
    assert_equals("Space has 3 shortcuts", #space, 3)

    -- Spot-check: panel-scoped shortcuts on correct panels
    local timeline_shortcuts = find_shortcuts_by_parent(containers.timeline)
    assert_true("timeline has shortcuts", #timeline_shortcuts > 10)

    local browser_shortcuts = find_shortcuts_by_parent(containers.project_browser)
    assert_true("browser has shortcuts", #browser_shortcuts >= 2)
end

local function test_recreate_destroys_previous()
    reset()
    local shortcut = registry.parse_shortcut("Q")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "SelectTool",
        positional_args = {},
        named_params = {},
        contexts = { "timeline" },
        category = "Timeline",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)
    assert_equals("first creation", #created_shortcuts, 1)

    -- Create again — should destroy old ones first
    registry.create_qt_shortcuts(containers)
    assert_equals("old shortcut deleted", #deleted_shortcuts, 1)
    assert_equals("new shortcut created", #created_shortcuts, 2)
end

local function test_digit_key_conversion()
    reset()
    -- Cmd+2 → SelectPanel inspector (global)
    local shortcut = registry.parse_shortcut("Cmd+2")
    local combo_key = string.format("%d_%d", shortcut.key, shortcut.modifiers)
    registry.keybindings[combo_key] = {{
        command_name = "SelectPanel",
        positional_args = { "inspector" },
        named_params = {},
        contexts = {},
        category = "View",
        shortcut = shortcut,
    }}

    registry.create_qt_shortcuts(containers)

    assert_equals("key_seq Ctrl+2", created_shortcuts[1].key_seq, "Ctrl+2")
end

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

local tests = {
    { "global shortcut → window context", test_global_shortcut_gets_window_context },
    { "panel-scoped → widget_children context", test_panel_scoped_shortcut_gets_widget_children },
    { "multi-context → multiple shortcuts", test_multi_context_creates_multiple_shortcuts },
    { "Cmd → Ctrl modifier conversion", test_modifier_conversion_cmd_to_ctrl },
    { "Ctrl → Meta on macOS", test_ctrl_becomes_meta_on_macos },
    { "symbol key (Tilde) conversion", test_symbol_key_conversion },
    { "bracket key conversion", test_bracket_key_conversion },
    { "handler executes command", test_handler_executes_command },
    { "handler passes named params", test_handler_passes_params },
    { "handler passes positional args", test_handler_passes_positional_args },
    { "destroy cleans up shortcuts + handlers", test_destroy_cleans_up },
    { "full TOML creates shortcuts", test_full_toml_creates_shortcuts },
    { "recreate destroys previous", test_recreate_destroys_previous },
    { "digit key conversion", test_digit_key_conversion },
}

for _, t in ipairs(tests) do
    local ok, err = pcall(t[2])
    if not ok then
        io.stderr:write(string.format("  ❌ %s: %s\n", t[1], tostring(err)))
        os.exit(1)
    end
    print(string.format("  ✅ %s", t[1]))
end

print("✅ test_keyboard_qshortcut_creation.lua passed")
os.exit(0)
