require('test_env')

-- Integration test: verify default.jvekeys parses correctly and populates registry.
-- Uses LITERAL Qt key codes (not keyboard_constants.KEY) to catch wrong-constant bugs.
-- If a constant in keyboard_constants.lua is wrong, the TOML parser stores the binding
-- under the wrong combo key — this test detects that by looking up with the real Qt values.
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

-- ── Literal Qt key codes (from Qt::Key enum, NOT from keyboard_constants) ──
-- These are the ground-truth values. If our keyboard_constants disagree,
-- the TOML parser will store bindings under wrong combo keys and these asserts fail.
local QT_KEY_SPACE     = 32
local QT_KEY_J         = 74
local QT_KEY_K         = 75
local QT_KEY_L         = 76
local QT_KEY_HOME      = 16777232   -- 0x01000010
local QT_KEY_END       = 16777233   -- 0x01000011
local QT_KEY_UP        = 16777235   -- 0x01000013
local QT_KEY_DOWN      = 16777237   -- 0x01000015
local QT_KEY_I         = 73
local QT_KEY_O         = 79
local QT_KEY_X         = 88
local QT_KEY_DELETE    = 16777223   -- 0x01000007
local QT_KEY_BACKSPACE = 16777219   -- 0x01000003
local QT_KEY_B         = 66
local QT_KEY_Z         = 90
local QT_KEY_N         = 78
local QT_KEY_RETURN    = 16777220   -- 0x01000004
local QT_KEY_F2        = 16777265   -- 0x01000031
local QT_KEY_2         = 50
local QT_KEY_3         = 51
local QT_MOD_SHIFT   = 0x02000000
local QT_MOD_CONTROL = 0x04000000  -- Qt::ControlModifier (= Cmd on macOS)

local function combo(key, mod_val)
    return string.format("%d_%d", key, mod_val or 0)
end

-- Find binding by command name from array of bindings for a combo key.
-- If expected_cmd is nil, returns first binding.
local function find_binding(key, mod_val, expected_cmd)
    local c = combo(key, mod_val)
    local bindings = registry.keybindings[c]
    if not bindings then return nil end
    if not expected_cmd then return bindings[1] end
    for _, b in ipairs(bindings) do
        if b.command_name == expected_cmd then return b end
    end
    return nil
end

local function assert_binding(key, mod_val, expected_cmd, label)
    local c = combo(key, mod_val)
    local bindings = registry.keybindings[c]
    assert(bindings and #bindings > 0, label .. ": binding missing for combo " .. c)
    local binding = find_binding(key, mod_val, expected_cmd)
    assert(binding,
        string.format("%s: expected %s, not found in bindings for combo %s", label, expected_cmd, c))
end

local function assert_positional(key, mod_val, idx, expected_val, label)
    local binding = find_binding(key, mod_val, nil)
    assert(binding, label .. ": binding missing")
    assert(binding.positional_args[idx] == expected_val,
        string.format("%s: positional[%d] expected %s, got %s",
            label, idx, expected_val, tostring(binding.positional_args[idx])))
end

local function assert_named(key, mod_val, param_name, expected_val, label)
    local binding = find_binding(key, mod_val, nil)
    assert(binding, label .. ": binding missing")
    assert(binding.named_params[param_name] == expected_val,
        string.format("%s: named[%s] expected %s, got %s",
            label, param_name, tostring(expected_val),
            tostring(binding.named_params[param_name])))
end

local function assert_contexts(key, mod_val, expected_contexts, label)
    local c = combo(key, mod_val)
    -- Collect all contexts across all bindings for this combo
    local ctx_set = {}
    local bindings = registry.keybindings[c]
    assert(bindings and #bindings > 0, label .. ": binding missing")
    for _, binding in ipairs(bindings) do
        for _, ctx in ipairs(binding.contexts) do ctx_set[ctx] = true end
    end
    for _, ectx in ipairs(expected_contexts) do
        assert(ctx_set[ectx],
            string.format("%s: missing context %s", label, ectx))
    end
end

-- ═════════════════════════════════════════
-- Transport
-- ═════════════════════════════════════════
print("\n--- Transport ---")
assert_binding(QT_KEY_SPACE, 0, "TogglePlay", "Space")
assert_binding(QT_KEY_J, 0, "ShuttleReverse", "J")
assert_binding(QT_KEY_K, 0, "ShuttleStop", "K")
assert_binding(QT_KEY_L, 0, "ShuttleForward", "L")
assert_contexts(QT_KEY_SPACE, 0, {"timeline", "source_monitor", "timeline_monitor"}, "Space contexts")
print("  ✓ Transport bindings: Space, J, K, L")

-- ═════════════════════════════════════════
-- Navigation
-- ═════════════════════════════════════════
print("\n--- Navigation ---")
assert_binding(QT_KEY_HOME, 0, "GoToStart", "Home")
assert_binding(QT_KEY_END, 0, "GoToEnd", "End")
assert_binding(QT_KEY_UP, 0, "GoToPrevEdit", "Up")
assert_binding(QT_KEY_DOWN, 0, "GoToNextEdit", "Down")
print("  ✓ Navigation bindings: Home, End, Up, Down")

-- ═════════════════════════════════════════
-- Marks (positional args)
-- ═════════════════════════════════════════
print("\n--- Marks ---")
assert_binding(QT_KEY_I, 0, "SetMark", "I")
assert_positional(QT_KEY_I, 0, 1, "in", "I positional")
assert_binding(QT_KEY_O, 0, "SetMark", "O")
assert_positional(QT_KEY_O, 0, 1, "out", "O positional")
assert_binding(QT_KEY_I, QT_MOD_SHIFT, "GoToMark", "Shift+I")
assert_positional(QT_KEY_I, QT_MOD_SHIFT, 1, "in", "Shift+I positional")
assert_binding(QT_KEY_O, QT_MOD_SHIFT, "GoToMark", "Shift+O")
assert_positional(QT_KEY_O, QT_MOD_SHIFT, 1, "out", "Shift+O positional")
assert_binding(QT_KEY_X, 0, "MarkClipExtent", "X")
print("  ✓ Mark bindings: I, O, Shift+I, Shift+O, X")

-- ═════════════════════════════════════════
-- Timeline editing
-- ═════════════════════════════════════════
print("\n--- Timeline editing ---")
assert_binding(QT_KEY_DELETE, 0, "DeleteSelection", "Delete")
assert_binding(QT_KEY_BACKSPACE, 0, "DeleteSelection", "Backspace")
assert_binding(QT_KEY_DELETE, QT_MOD_SHIFT, "DeleteSelection", "Shift+Delete")
assert_named(QT_KEY_DELETE, QT_MOD_SHIFT, "ripple", true, "Shift+Delete ripple")
assert_binding(QT_KEY_B, QT_MOD_CONTROL, "Blade", "Cmd+B")
assert_contexts(QT_KEY_B, QT_MOD_CONTROL, {"timeline"}, "Cmd+B contexts")
print("  ✓ Editing bindings: Delete, Backspace, Shift+Delete(ripple), Cmd+B")

-- ═════════════════════════════════════════
-- Zoom
-- ═════════════════════════════════════════
print("\n--- Zoom ---")
assert_binding(QT_KEY_Z, QT_MOD_SHIFT, "TimelineZoomFit", "Shift+Z")
print("  ✓ Zoom bindings: Shift+Z")

-- ═════════════════════════════════════════
-- View
-- ═════════════════════════════════════════
print("\n--- View ---")
assert_binding(QT_KEY_2, QT_MOD_CONTROL, "SelectPanel", "Cmd+2")
assert_positional(QT_KEY_2, QT_MOD_CONTROL, 1, "inspector", "Cmd+2 positional")
assert_binding(QT_KEY_3, QT_MOD_CONTROL, "SelectPanel", "Cmd+3")
assert_positional(QT_KEY_3, QT_MOD_CONTROL, 1, "timeline", "Cmd+3 positional")
print("  ✓ View bindings: Cmd+2, Cmd+3")

-- ═════════════════════════════════════════
-- Application (global, no context)
-- ═════════════════════════════════════════
print("\n--- Application ---")
assert_binding(QT_KEY_Z, QT_MOD_CONTROL, "Undo", "Cmd+Z")
assert_binding(QT_KEY_Z, QT_MOD_CONTROL + QT_MOD_SHIFT, "Redo", "Cmd+Shift+Z")
-- Global commands should have empty contexts
do
    local binding = find_binding(QT_KEY_Z, QT_MOD_CONTROL, "Undo")
    assert(binding, "Undo binding missing")
    assert(#binding.contexts == 0,
        "Undo should be global (no context restriction), got " .. #binding.contexts .. " contexts")
end
print("  ✓ Application bindings: Cmd+Z (global), Cmd+Shift+Z (global)")

-- ═════════════════════════════════════════
-- Snapping
-- ═════════════════════════════════════════
print("\n--- Snapping ---")
assert_binding(QT_KEY_N, 0, "ToggleSnapping", "N")
assert_contexts(QT_KEY_N, 0, {"timeline"}, "N contexts")
print("  ✓ Snapping binding: N")

-- ═════════════════════════════════════════
-- Browser
-- ═════════════════════════════════════════
print("\n--- Browser ---")
assert_binding(QT_KEY_RETURN, 0, "ActivateBrowserSelection", "Return")
assert_contexts(QT_KEY_RETURN, 0, {"project_browser"}, "Return contexts")
print("  ✓ Browser binding: Return")

-- ═════════════════════════════════════════
-- Rename (F2) — regression test for F2 constant collision with Qt::Key_Control
-- ═════════════════════════════════════════
print("\n--- Rename ---")
assert_binding(QT_KEY_F2, 0, "RenameItem", "F2")
assert_contexts(QT_KEY_F2, 0, {"project_browser"}, "F2 contexts")
print("  ✓ F2 → RenameItem (not confused with Control key)")

print("\n✅ test_toml_keybinding_loading.lua passed")
