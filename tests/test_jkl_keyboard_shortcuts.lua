require('test_env')

-- This test verifies the JKL keyboard shortcut integration in keyboard_shortcuts.lua
-- Tests the handle_key_release function and K held state tracking

print("=== Test JKL Keyboard Shortcuts Integration ===")

-- Mock qt_create_single_shot_timer
_G.qt_create_single_shot_timer = function(interval, callback)
    -- No-op for keyboard tests
end

-- We need to test handle_key_release, which requires keyboard_shortcuts module
-- First, set up minimal mocks

-- Mock panel_manager
package.loaded["ui.panel_manager"] = {
    toggle_active_panel = function() end,
}

-- Mock keyboard_shortcut_registry
package.loaded["core.keyboard_shortcut_registry"] = {
    commands = {},
    register_command = function() end,
    assign_shortcut = function() return true end,
    handle_key_event = function() return false end,
}

-- Mock focus_manager
_G.focus_manager = nil

-- Load keyboard_shortcuts
package.loaded["core.keyboard_shortcuts"] = nil
local keyboard_shortcuts = require("core.keyboard_shortcuts")

-- Get KEY constants
local KEY = keyboard_shortcuts.KEY

print("\n--- Test K key release tracking ---")

print("\nTest 1: handle_key_release exists")
assert(type(keyboard_shortcuts.handle_key_release) == "function", "handle_key_release should be a function")
print("  ✓ handle_key_release function exists")

print("\nTest 2: handle_key_release with K key")
local result = keyboard_shortcuts.handle_key_release({key = KEY.K})
assert(result == false, "handle_key_release should return false (not consume event)")
print("  ✓ handle_key_release(K) returns false")

print("\nTest 3: handle_key_release with non-K key")
result = keyboard_shortcuts.handle_key_release({key = KEY.J})
assert(result == false, "handle_key_release should return false for J")
print("  ✓ handle_key_release(J) returns false")

print("\nTest 4: handle_key_release with L key")
result = keyboard_shortcuts.handle_key_release({key = KEY.L})
assert(result == false, "handle_key_release should return false for L")
print("  ✓ handle_key_release(L) returns false")

print("\nTest 5: handle_key_release with Space key")
result = keyboard_shortcuts.handle_key_release({key = KEY.Space})
assert(result == false, "handle_key_release should return false for Space")
print("  ✓ handle_key_release(Space) returns false")

print("\n--- Test KEY constants for JKL ---")

print("\nTest 6: KEY.J is defined")
assert(KEY.J ~= nil, "KEY.J should be defined")
assert(KEY.J == 74, "KEY.J should be Qt key code 74")
print("  ✓ KEY.J = 74")

print("\nTest 7: KEY.K is defined")
assert(KEY.K ~= nil, "KEY.K should be defined")
assert(KEY.K == 75, "KEY.K should be Qt key code 75")
print("  ✓ KEY.K = 75")

print("\nTest 8: KEY.L is defined")
assert(KEY.L ~= nil, "KEY.L should be defined")
assert(KEY.L == 76, "KEY.L should be Qt key code 76")
print("  ✓ KEY.L = 76")

print("\n✅ test_jkl_keyboard_shortcuts.lua passed")
