#!/usr/bin/env luajit

-- Test multi-context keybinding dispatch: same key combo with different contexts
-- dispatches to the correct command based on active panel focus.
-- Uses the real keyboard_shortcut_registry with mock command_manager.

require("test_env")

print("=== Test Multi-Context Keybinding Dispatch ===")

-- Track dispatched commands
local dispatched = {}
local mock_cm = {
    get_executor = function() return function() end end,
    execute_ui = function(command_name, params)
        dispatched[#dispatched + 1] = { command = command_name, params = params }
        return { success = true }
    end,
}

-- Load registry fresh
package.loaded["core.keyboard_shortcut_registry"] = nil
local registry = require("core.keyboard_shortcut_registry")
registry.set_command_manager(mock_cm)

-- Load the real keybindings (which now include both timeline and source_monitor zoom)
registry.load_keybindings("../keymaps/default.jvekeys")

-- Qt key constants (literal values, not from keyboard_constants)
local QT_KEY_Z     = 90
local QT_KEY_EQUAL = 61    -- '=' key
local QT_MOD_SHIFT   = 0x02000000
local QT_MOD_CONTROL = 0x04000000  -- Cmd on macOS

--------------------------------------------------------------------------------
-- Test 1: Shift+Z dispatches TimelineZoomFit when timeline focused
--------------------------------------------------------------------------------
print("\n--- Test 1: Shift+Z @timeline ---")
dispatched = {}
local handled = registry.handle_key_event(QT_KEY_Z, QT_MOD_SHIFT, "timeline")
assert(handled, "Shift+Z should be handled in timeline context")
assert(#dispatched == 1, "should dispatch exactly 1 command")
assert(dispatched[1].command == "TimelineZoomFit",
    "should dispatch TimelineZoomFit, got " .. tostring(dispatched[1].command))
print("  ok: TimelineZoomFit dispatched")

--------------------------------------------------------------------------------
-- Test 2: Shift+Z dispatches SourceZoomFit when source_monitor focused
--------------------------------------------------------------------------------
print("\n--- Test 2: Shift+Z @source_monitor ---")
dispatched = {}
handled = registry.handle_key_event(QT_KEY_Z, QT_MOD_SHIFT, "source_monitor")
assert(handled, "Shift+Z should be handled in source_monitor context")
assert(#dispatched == 1, "should dispatch exactly 1 command")
assert(dispatched[1].command == "SourceZoomFit",
    "should dispatch SourceZoomFit, got " .. tostring(dispatched[1].command))
print("  ok: SourceZoomFit dispatched")

--------------------------------------------------------------------------------
-- Test 3: Shift+Z does NOT dispatch in unrelated context
--------------------------------------------------------------------------------
print("\n--- Test 3: Shift+Z @project_browser ---")
dispatched = {}
handled = registry.handle_key_event(QT_KEY_Z, QT_MOD_SHIFT, "project_browser")
assert(not handled, "Shift+Z should NOT be handled in project_browser context")
assert(#dispatched == 0, "should dispatch 0 commands")
print("  ok: not dispatched in project_browser")

--------------------------------------------------------------------------------
-- Test 4: Cmd+= dispatches TimelineZoomIn when timeline focused
--------------------------------------------------------------------------------
print("\n--- Test 4: Cmd+= @timeline ---")
dispatched = {}
handled = registry.handle_key_event(QT_KEY_EQUAL, QT_MOD_CONTROL, "timeline")
assert(handled, "Cmd+= should be handled in timeline context")
assert(#dispatched == 1, "should dispatch exactly 1 command")
assert(dispatched[1].command == "TimelineZoomIn",
    "should dispatch TimelineZoomIn, got " .. tostring(dispatched[1].command))
print("  ok: TimelineZoomIn dispatched")

--------------------------------------------------------------------------------
-- Test 5: Cmd+= dispatches SourceZoomIn when source_monitor focused
--------------------------------------------------------------------------------
print("\n--- Test 5: Cmd+= @source_monitor ---")
dispatched = {}
handled = registry.handle_key_event(QT_KEY_EQUAL, QT_MOD_CONTROL, "source_monitor")
assert(handled, "Cmd+= should be handled in source_monitor context")
assert(#dispatched == 1, "should dispatch exactly 1 command")
assert(dispatched[1].command == "SourceZoomIn",
    "should dispatch SourceZoomIn, got " .. tostring(dispatched[1].command))
print("  ok: SourceZoomIn dispatched")

--------------------------------------------------------------------------------
-- Test 6: Global bindings still work (Cmd+Z = Undo, no context restriction)
--------------------------------------------------------------------------------
print("\n--- Test 6: global binding Cmd+Z ---")
dispatched = {}
handled = registry.handle_key_event(QT_KEY_Z, QT_MOD_CONTROL, "timeline")
assert(handled, "Cmd+Z should be handled globally")
assert(dispatched[1].command == "Undo",
    "should dispatch Undo, got " .. tostring(dispatched[1].command))

dispatched = {}
handled = registry.handle_key_event(QT_KEY_Z, QT_MOD_CONTROL, "source_monitor")
assert(handled, "Cmd+Z should be handled in any context")
assert(dispatched[1].command == "Undo",
    "should dispatch Undo in source_monitor too")
print("  ok: global Undo works in any context")

--------------------------------------------------------------------------------
-- Test 7: Context-specific bindings take priority over global
--------------------------------------------------------------------------------
print("\n--- Test 7: context beats global ---")
-- Register a mock global binding and a context-specific binding for same combo
local test_combo = "999_0"
registry.keybindings[test_combo] = {
    { command_name = "GlobalCmd", positional_args = {}, named_params = {},
      contexts = {}, category = "Test" },
    { command_name = "ContextCmd", positional_args = {}, named_params = {},
      contexts = {"timeline"}, category = "Test" },
}

dispatched = {}
handled = registry.handle_key_event(999, 0, "timeline")
assert(handled, "should handle key")
assert(dispatched[1].command == "ContextCmd",
    "context-specific should win over global, got " .. tostring(dispatched[1].command))

-- In non-matching context, global should still work
dispatched = {}
handled = registry.handle_key_event(999, 0, "project_browser")
assert(handled, "should handle via global fallback")
assert(dispatched[1].command == "GlobalCmd",
    "global should handle non-matching context, got " .. tostring(dispatched[1].command))
print("  ok: context-specific > global")

--------------------------------------------------------------------------------
-- Test 8: Multiple bindings in array for same combo
--------------------------------------------------------------------------------
print("\n--- Test 8: array bindings ---")
local combo_key = string.format("%d_%d", QT_KEY_Z, QT_MOD_SHIFT)
local bindings = registry.keybindings[combo_key]
assert(bindings, "bindings array should exist for Shift+Z")
assert(#bindings >= 2,
    "Shift+Z should have at least 2 bindings (timeline + source_monitor), got " .. #bindings)

-- Verify both commands are present
local found_timeline = false
local found_source = false
for _, b in ipairs(bindings) do
    if b.command_name == "TimelineZoomFit" then found_timeline = true end
    if b.command_name == "SourceZoomFit" then found_source = true end
end
assert(found_timeline, "TimelineZoomFit binding missing")
assert(found_source, "SourceZoomFit binding missing")
print("  ok: both bindings in array")

-- Cleanup test entry
registry.keybindings["999_0"] = nil

print("\n✅ test_keybinding_multi_context.lua passed")
