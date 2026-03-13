#!/usr/bin/env luajit

-- Test: Qt6 shifted-symbol normalization in keyboard dispatch.
--
-- Three equivalent TOML notations must produce the same combo_key:
--   "Tilde"        — canonical shifted key, no Shift modifier
--   "Shift+Grave"  — unshifted key + Shift → promoted to Tilde, Shift stripped
--   "Shift+Tilde"  — redundant Shift on already-shifted key → stripped
--
-- At runtime Qt6 sends key=Tilde(126)+Shift for Shift+`; handle_key_event
-- strips the redundant Shift to match the canonical form.

require("test_env")

print("=== Test Shifted Symbol Key Normalization ===")

local kb_constants = require("core.keyboard_constants")
local QT_MOD_SHIFT = kb_constants.MOD.Shift
local QT_MOD_CMD = kb_constants.MOD.Control  -- Cmd on macOS = Qt ControlModifier
local QT_KEY_TILDE = kb_constants.KEY.Tilde  -- 126

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

--------------------------------------------------------------------------------
-- Test 1: parse_shortcut — all three forms produce same combo_key
--------------------------------------------------------------------------------
print("\n--- Test 1: parse_shortcut equivalence ---")
local s1 = registry.parse_shortcut("Tilde")
local s2 = registry.parse_shortcut("Shift+Grave")
local s3 = registry.parse_shortcut("Shift+Tilde")
assert(s1 and s2 and s3, "all three forms must parse")
assert(s1.key == s2.key and s1.key == s3.key,
    string.format("key mismatch: Tilde=%d Shift+Grave=%d Shift+Tilde=%d",
        s1.key, s2.key, s3.key))
assert(s1.modifiers == s2.modifiers and s1.modifiers == s3.modifiers,
    string.format("modifier mismatch: Tilde=0x%x Shift+Grave=0x%x Shift+Tilde=0x%x",
        s1.modifiers, s2.modifiers, s3.modifiers))
assert(s1.key == 126, "canonical key should be Tilde (126)")
assert(s1.modifiers == 0, "canonical modifiers should be 0 (no Shift)")
print("  ok: Tilde == Shift+Grave == Shift+Tilde → key=126, mod=0")

--------------------------------------------------------------------------------
-- Test 2: parse_shortcut — Cmd variants are equivalent too
--------------------------------------------------------------------------------
print("\n--- Test 2: Cmd+Tilde == Cmd+Shift+Grave == Cmd+Shift+Tilde ---")
local c1 = registry.parse_shortcut("Cmd+Tilde")
local c2 = registry.parse_shortcut("Cmd+Shift+Grave")
local c3 = registry.parse_shortcut("Cmd+Shift+Tilde")
assert(c1 and c2 and c3, "all three Cmd forms must parse")
assert(c1.key == c2.key and c1.key == c3.key,
    string.format("key mismatch: %d %d %d", c1.key, c2.key, c3.key))
assert(c1.modifiers == c2.modifiers and c1.modifiers == c3.modifiers,
    string.format("mod mismatch: 0x%x 0x%x 0x%x", c1.modifiers, c2.modifiers, c3.modifiers))
assert(c1.key == 126, "canonical key should be Tilde (126)")
assert(c1.modifiers == QT_MOD_CMD, "should have only Cmd modifier")
print("  ok")

--------------------------------------------------------------------------------
-- Test 3: parse_shortcut — bracket equivalence
--------------------------------------------------------------------------------
print("\n--- Test 3: Cmd+BraceLeft == Cmd+Shift+BracketLeft ---")
local b1 = registry.parse_shortcut("Cmd+BraceLeft")
local b2 = registry.parse_shortcut("Cmd+Shift+BracketLeft")
assert(b1 and b2, "both bracket forms must parse")
assert(b1.key == b2.key,
    string.format("key mismatch: %d vs %d", b1.key, b2.key))
assert(b1.modifiers == b2.modifiers,
    string.format("mod mismatch: 0x%x vs 0x%x", b1.modifiers, b2.modifiers))
assert(b1.key == 123, "canonical key should be BraceLeft (123)")
assert(b1.modifiers == QT_MOD_CMD, "should have only Cmd modifier")
print("  ok")

--------------------------------------------------------------------------------
-- Test 4: runtime — Tilde+Shift (Qt6 actual event) matches "Tilde" binding
--------------------------------------------------------------------------------
print("\n--- Test 4: runtime Tilde+Shift → ToggleMaximizePanel ---")
registry.load_keybindings("../keymaps/default.jvekeys")

dispatched = {}
local handled = registry.handle_key_event(QT_KEY_TILDE, 0, "timeline")
assert(handled, "Tilde (no Shift) should match")
assert(dispatched[1].command == "ToggleMaximizePanel",
    "got " .. tostring(dispatched[1].command))

dispatched = {}
handled = registry.handle_key_event(QT_KEY_TILDE, QT_MOD_SHIFT, "timeline")
assert(handled, "Tilde+Shift (Qt6 event) should match after normalization")
assert(dispatched[1].command == "ToggleMaximizePanel",
    "got " .. tostring(dispatched[1].command))
print("  ok")

--------------------------------------------------------------------------------
-- Test 5: runtime — additional modifiers preserved after Shift strip
--------------------------------------------------------------------------------
print("\n--- Test 5: Cmd+Tilde+Shift preserves Cmd, strips Shift ---")
dispatched = {}
handled = registry.handle_key_event(QT_KEY_TILDE, QT_MOD_SHIFT + QT_MOD_CMD, "timeline")
assert(not handled, "Cmd+Tilde has no binding — should not match")
assert(#dispatched == 0, "should dispatch 0 commands")
print("  ok")

--------------------------------------------------------------------------------
-- Test 6: SHIFTED_SYMBOL_KEYS table completeness
--------------------------------------------------------------------------------
print("\n--- Test 6: SHIFTED_SYMBOL_KEYS completeness ---")
local expected_shifted = {
    43, 126, 33, 64, 35, 36, 37, 94, 38, 42, 40, 41,
    95, 123, 125, 124, 58, 34, 60, 62, 63,
}
for _, code in ipairs(expected_shifted) do
    assert(kb_constants.SHIFTED_SYMBOL_KEYS[code],
        string.format("missing code %d ('%s')", code, string.char(code)))
end
print("  ok: all " .. #expected_shifted .. " shifted codes present")

--------------------------------------------------------------------------------
-- Test 7: UNSHIFTED_TO_SHIFTED table consistency
-- Every mapped value must exist in SHIFTED_SYMBOL_KEYS
--------------------------------------------------------------------------------
print("\n--- Test 7: UNSHIFTED_TO_SHIFTED → SHIFTED_SYMBOL_KEYS consistency ---")
local count = 0
for unshifted, shifted in pairs(kb_constants.UNSHIFTED_TO_SHIFTED) do
    assert(kb_constants.SHIFTED_SYMBOL_KEYS[shifted],
        string.format("UNSHIFTED_TO_SHIFTED[%d]=%d not in SHIFTED_SYMBOL_KEYS",
            unshifted, shifted))
    count = count + 1
end
-- Every shifted symbol has a corresponding unshifted source
assert(count == #expected_shifted,
    "expected " .. #expected_shifted .. " mappings, got " .. count)
print("  ok: all " .. count .. " mappings valid")

--------------------------------------------------------------------------------
-- Test 8: non-shifted keys unaffected
--------------------------------------------------------------------------------
print("\n--- Test 8: non-shifted keys not in table ---")
local non_shifted = {
    kb_constants.KEY.A, kb_constants.KEY.Space, kb_constants.KEY.Grave,
    kb_constants.KEY.BracketLeft, kb_constants.KEY.Equal,
    kb_constants.KEY.Comma, kb_constants.KEY.Period, kb_constants.KEY.Minus,
}
for _, code in ipairs(non_shifted) do
    assert(not kb_constants.SHIFTED_SYMBOL_KEYS[code],
        string.format("should NOT contain unshifted code %d", code))
end
print("  ok")

print("\n✅ test_keybinding_shifted_symbol.lua passed")
