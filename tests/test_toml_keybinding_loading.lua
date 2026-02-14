require('test_env')

-- Integration test: verify default.jvekeys parses correctly and populates registry
print("=== Test TOML Keybinding Loading ===")

-- We need command_manager mock for the registry
local mock_cm = {
    get_executor = function() return function() end end,
    execute_ui = function() return { success = true } end,
}

-- Load registry fresh
package.loaded["core.keyboard_shortcut_registry"] = nil
local registry = require("core.keyboard_shortcut_registry")
registry.set_command_manager(mock_cm)

-- Load keybindings
registry.load_keybindings("../keymaps/default.jvekeys")

local kb = require("core.keyboard_constants")
local KEY = kb.KEY
local MOD = kb.MOD

local function combo(key, mod_val)
    return string.format("%d_%d", key, mod_val or 0)
end

local function assert_binding(key, mod_val, expected_cmd, label)
    local c = combo(key, mod_val)
    local binding = registry.keybindings[c]
    assert(binding, label .. ": binding missing for combo " .. c)
    assert(binding.command_name == expected_cmd,
        string.format("%s: expected %s, got %s", label, expected_cmd, binding.command_name))
end

local function assert_positional(key, mod_val, idx, expected_val, label)
    local c = combo(key, mod_val)
    local binding = registry.keybindings[c]
    assert(binding, label .. ": binding missing")
    assert(binding.positional_args[idx] == expected_val,
        string.format("%s: positional[%d] expected %s, got %s",
            label, idx, expected_val, tostring(binding.positional_args[idx])))
end

local function assert_named(key, mod_val, param_name, expected_val, label)
    local c = combo(key, mod_val)
    local binding = registry.keybindings[c]
    assert(binding, label .. ": binding missing")
    assert(binding.named_params[param_name] == expected_val,
        string.format("%s: named[%s] expected %s, got %s",
            label, param_name, tostring(expected_val),
            tostring(binding.named_params[param_name])))
end

local function assert_contexts(key, mod_val, expected_contexts, label)
    local c = combo(key, mod_val)
    local binding = registry.keybindings[c]
    assert(binding, label .. ": binding missing")
    local ctx_set = {}
    for _, ctx in ipairs(binding.contexts) do ctx_set[ctx] = true end
    for _, ectx in ipairs(expected_contexts) do
        assert(ctx_set[ectx],
            string.format("%s: missing context %s", label, ectx))
    end
end

-- ═════════════════════════════════════════
-- Transport
-- ═════════════════════════════════════════
print("\n--- Transport ---")
assert_binding(KEY.Space, 0, "TogglePlay", "Space")
assert_binding(KEY.J, 0, "ShuttleReverse", "J")
assert_binding(KEY.K, 0, "ShuttleStop", "K")
assert_binding(KEY.L, 0, "ShuttleForward", "L")
assert_contexts(KEY.Space, 0, {"timeline", "source_monitor", "timeline_monitor"}, "Space contexts")
print("  ✓ Transport bindings: Space, J, K, L")

-- ═════════════════════════════════════════
-- Navigation
-- ═════════════════════════════════════════
print("\n--- Navigation ---")
assert_binding(KEY.Home, 0, "GoToStart", "Home")
assert_binding(KEY.End, 0, "GoToEnd", "End")
assert_binding(KEY.Up, 0, "GoToPrevEdit", "Up")
assert_binding(KEY.Down, 0, "GoToNextEdit", "Down")
print("  ✓ Navigation bindings: Home, End, Up, Down")

-- ═════════════════════════════════════════
-- Marks (positional args)
-- ═════════════════════════════════════════
print("\n--- Marks ---")
assert_binding(KEY.I, 0, "SetMark", "I")
assert_positional(KEY.I, 0, 1, "in", "I positional")
assert_binding(KEY.O, 0, "SetMark", "O")
assert_positional(KEY.O, 0, 1, "out", "O positional")
assert_binding(KEY.I, MOD.Shift, "GoToMark", "Shift+I")
assert_positional(KEY.I, MOD.Shift, 1, "in", "Shift+I positional")
assert_binding(KEY.O, MOD.Shift, "GoToMark", "Shift+O")
assert_positional(KEY.O, MOD.Shift, 1, "out", "Shift+O positional")
assert_binding(KEY.X, 0, "MarkClipExtent", "X")
print("  ✓ Mark bindings: I, O, Shift+I, Shift+O, X")

-- ═════════════════════════════════════════
-- Timeline editing
-- ═════════════════════════════════════════
print("\n--- Timeline editing ---")
assert_binding(KEY.Delete, 0, "DeleteSelection", "Delete")
assert_binding(KEY.Backspace, 0, "DeleteSelection", "Backspace")
assert_binding(KEY.Delete, MOD.Shift, "DeleteSelection", "Shift+Delete")
assert_named(KEY.Delete, MOD.Shift, "ripple", true, "Shift+Delete ripple")
assert_binding(KEY.B, MOD.Meta, "Blade", "Cmd+B")
assert_contexts(KEY.B, MOD.Meta, {"timeline"}, "Cmd+B contexts")
print("  ✓ Editing bindings: Delete, Backspace, Shift+Delete(ripple), Cmd+B")

-- ═════════════════════════════════════════
-- Zoom
-- ═════════════════════════════════════════
print("\n--- Zoom ---")
assert_binding(KEY.Z, MOD.Shift, "TimelineZoomFit", "Shift+Z")
print("  ✓ Zoom bindings: Shift+Z")

-- ═════════════════════════════════════════
-- View
-- ═════════════════════════════════════════
print("\n--- View ---")
assert_binding(KEY.Key2, MOD.Meta, "SelectPanel", "Cmd+2")
assert_positional(KEY.Key2, MOD.Meta, 1, "inspector", "Cmd+2 positional")
assert_binding(KEY.Key3, MOD.Meta, "SelectPanel", "Cmd+3")
assert_positional(KEY.Key3, MOD.Meta, 1, "timeline", "Cmd+3 positional")
print("  ✓ View bindings: Cmd+2, Cmd+3")

-- ═════════════════════════════════════════
-- Application (global, no context)
-- ═════════════════════════════════════════
print("\n--- Application ---")
assert_binding(KEY.Z, MOD.Meta, "Undo", "Cmd+Z")
assert_binding(KEY.Z, MOD.Meta + MOD.Shift, "Redo", "Cmd+Shift+Z")
-- Global commands should have empty contexts
do
    local c = combo(KEY.Z, MOD.Meta)
    local binding = registry.keybindings[c]
    assert(#binding.contexts == 0,
        "Undo should be global (no context restriction), got " .. #binding.contexts .. " contexts")
end
print("  ✓ Application bindings: Cmd+Z (global), Cmd+Shift+Z (global)")

-- ═════════════════════════════════════════
-- Snapping
-- ═════════════════════════════════════════
print("\n--- Snapping ---")
assert_binding(KEY.N, 0, "ToggleSnapping", "N")
assert_contexts(KEY.N, 0, {"timeline"}, "N contexts")
print("  ✓ Snapping binding: N")

-- ═════════════════════════════════════════
-- Browser
-- ═════════════════════════════════════════
print("\n--- Browser ---")
assert_binding(KEY.Return, 0, "ActivateBrowserSelection", "Return")
assert_contexts(KEY.Return, 0, {"project_browser"}, "Return contexts")
print("  ✓ Browser binding: Return")

print("\n✅ test_toml_keybinding_loading.lua passed")
