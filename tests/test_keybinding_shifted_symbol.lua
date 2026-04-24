#!/usr/bin/env luajit

-- Test: Qt6 shifted-symbol normalization in keyboard dispatch.
--
-- Canonical form: UNSHIFTED key + Shift modifier (if shift was involved).
-- Three equivalent TOML notations all normalize to the same combo_key:
--   "Tilde"        — shifted name as sugar → demoted to Grave, Shift added
--   "Shift+Grave"  — already canonical
--   "Shift+Tilde"  — redundant shifted name → demoted to Grave, Shift kept
--
-- At runtime Qt6 sends key=Tilde(126)+Shift for Shift+`; handle_key_event
-- demotes the key to Grave(96) and preserves Shift so the combo matches.
--
-- Keypad keys (e.g. Plus from numpad +) arrive WITHOUT Shift and are NOT
-- demoted — they remain distinct bindings so a numpad-only binding can
-- coexist with Shift+Equal.

require("test_env")

print("=== Test Shifted Symbol Key Normalization ===")

local kb_constants = require("core.keyboard_constants")
local QT_MOD_SHIFT = kb_constants.MOD.Shift
local QT_MOD_CMD = kb_constants.MOD.Control  -- Cmd on macOS = Qt ControlModifier
local QT_KEY_TILDE = kb_constants.KEY.Tilde  -- 126
local QT_KEY_GRAVE = kb_constants.KEY.Grave  -- 96
local QT_KEY_PLUS = kb_constants.KEY.Plus    -- 43

-- Track dispatched commands
local dispatched = {}
local mock_cm = {
    get_executor = function() return function() end end,
    execute_interactive = function(command_name, params)
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
assert(s1.key == QT_KEY_GRAVE,
    string.format("canonical key should be Grave (%d), got %d", QT_KEY_GRAVE, s1.key))
assert(s1.modifiers == QT_MOD_SHIFT,
    string.format("canonical modifiers should be Shift only, got 0x%x", s1.modifiers))
print("  ok: Tilde == Shift+Grave == Shift+Tilde → key=Grave, mod=Shift")

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
assert(c1.key == QT_KEY_GRAVE, "canonical key should be Grave")
local expected_cmd_shift = QT_MOD_CMD + QT_MOD_SHIFT
assert(c1.modifiers == expected_cmd_shift,
    string.format("should have Cmd+Shift, got 0x%x", c1.modifiers))
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
assert(b1.key == kb_constants.KEY.BracketLeft,
    string.format("canonical key should be BracketLeft (%d), got %d",
        kb_constants.KEY.BracketLeft, b1.key))
assert(b1.modifiers == expected_cmd_shift,
    string.format("should have Cmd+Shift, got 0x%x", b1.modifiers))
print("  ok")

--------------------------------------------------------------------------------
-- Test 4: parse_shortcut — Cmd+Equal vs Cmd+Plus resolve DIFFERENTLY.
-- Cmd+Equal → key=Equal, mod=Cmd (no Shift).
-- Cmd+Plus → demoted to key=Equal, mod=Cmd+Shift.
-- This is the whole point of the canonical flip: the two combos are
-- distinguishable, so zoom-in and zoom-in-at-pointer can bind separately.
--------------------------------------------------------------------------------
print("\n--- Test 4: Cmd+Equal vs Cmd+Plus are distinct ---")
local eq = registry.parse_shortcut("Cmd+Equal")
local pl = registry.parse_shortcut("Cmd+Plus")
assert(eq and pl, "both must parse")
assert(eq.key == pl.key, "both demote to same key (Equal)")
assert(eq.key == kb_constants.KEY.Equal, "key should be Equal")
assert(eq.modifiers == QT_MOD_CMD, "Cmd+Equal should have Cmd only")
assert(pl.modifiers == expected_cmd_shift, "Cmd+Plus should have Cmd+Shift")
assert(eq.modifiers ~= pl.modifiers, "they MUST differ so bindings can diverge")
print("  ok: Cmd+Equal and Cmd+Plus are separable bindings")

--------------------------------------------------------------------------------
-- Test 5: runtime — Qt sends Tilde+Shift for Shift+`; demoted to Grave+Shift
--------------------------------------------------------------------------------
print("\n--- Test 5: runtime Tilde+Shift → matches Shift+Grave binding ---")
registry.load_keybindings("../keymaps/default.jvekeys")

dispatched = {}
local handled = registry.handle_key_event(QT_KEY_TILDE, QT_MOD_SHIFT, "timeline")
assert(handled, "Tilde+Shift (Qt6 event for Shift+`) should match the Tilde binding")
assert(dispatched[1].command == "ToggleMaximizePanel",
    "got " .. tostring(dispatched[1].command))
print("  ok")

--------------------------------------------------------------------------------
-- Test 6: runtime — keypad Plus without Shift is NOT demoted
-- A raw Plus event (no Shift) must stay as Plus so numpad bindings
-- are distinct from Shift+Equal.
--------------------------------------------------------------------------------
print("\n--- Test 6: keypad Plus (no Shift) does not demote ---")
dispatched = {}
handled = registry.handle_key_event(QT_KEY_PLUS, 0, "timeline")
-- There's no binding for raw Plus in the default keymap; we're asserting
-- the handler did NOT silently rewrite the key to Equal+Shift.
-- If demotion had happened incorrectly, it'd match Cmd+Plus-less binding (none).
-- We verify by checking there's no false positive and no crash.
assert(not handled, "raw Plus has no binding; should be unhandled, not demoted")
assert(#dispatched == 0, "should dispatch 0 commands")
print("  ok: Plus without Shift stays as Plus (numpad-friendly)")

--------------------------------------------------------------------------------
-- Test 7: SHIFTED_TO_UNSHIFTED table completeness and consistency
--------------------------------------------------------------------------------
print("\n--- Test 7: SHIFTED_TO_UNSHIFTED table ---")
local expected_shifted = {
    43, 126, 33, 64, 35, 36, 37, 94, 38, 42, 40, 41,
    95, 123, 125, 124, 58, 34, 60, 62, 63,
}
for _, code in ipairs(expected_shifted) do
    assert(kb_constants.SHIFTED_TO_UNSHIFTED[code],
        string.format("missing demotion for code %d ('%s')", code, string.char(code)))
end
print("  ok: all " .. #expected_shifted .. " shifted codes have demotions")

--------------------------------------------------------------------------------
-- Test 8: non-shifted keys are not in the table
--------------------------------------------------------------------------------
print("\n--- Test 8: non-shifted keys absent from SHIFTED_TO_UNSHIFTED ---")
local non_shifted = {
    kb_constants.KEY.A, kb_constants.KEY.Space, kb_constants.KEY.Grave,
    kb_constants.KEY.BracketLeft, kb_constants.KEY.Equal,
    kb_constants.KEY.Comma, kb_constants.KEY.Period, kb_constants.KEY.Minus,
}
for _, code in ipairs(non_shifted) do
    assert(not kb_constants.SHIFTED_TO_UNSHIFTED[code],
        string.format("should NOT contain unshifted code %d", code))
end
print("  ok")

print("\n✅ test_keybinding_shifted_symbol.lua passed")
