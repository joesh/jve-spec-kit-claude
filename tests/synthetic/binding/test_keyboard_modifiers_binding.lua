--- T-FR005 (025) — qt_keyboard_modifiers C++ binding (spec 025 FR-005).
---
--- The track-header M/S click handler reads the live keyboard-modifier state
--- to choose ExclusiveToggle (Option/Alt held) vs the plain toggle, because a
--- QPushButton click carries no modifier flags. This binding exposes that
--- state. Must run in --test mode (the binding is a real C++ global).
---
--- Domain contract: GET_KEYBOARD_MODIFIERS() returns a table of four boolean
--- fields — alt, shift, cmd, ctrl. With no keys physically held during the
--- test, every field is false. (Holding a real modifier is an L3 smoke
--- concern; here we pin the binding's shape + type contract.)

require("test_env")

local qt_constants = require("core.qt_constants")

print("=== test_keyboard_modifiers_binding ===")

assert(qt_constants.INPUT and qt_constants.INPUT.GET_KEYBOARD_MODIFIERS,
    "qt_constants.INPUT.GET_KEYBOARD_MODIFIERS must be exposed (FR-005)")

local mods = qt_constants.INPUT.GET_KEYBOARD_MODIFIERS()
assert(type(mods) == "table", "GET_KEYBOARD_MODIFIERS must return a table")

for _, key in ipairs({ "alt", "shift", "cmd", "ctrl" }) do
    assert(type(mods[key]) == "boolean", string.format(
        "modifier field '%s' must be a boolean; got %s", key, type(mods[key])))
    assert(mods[key] == false, string.format(
        "no modifier is physically held in the test harness, so '%s' must be false", key))
end

print("  PASS: GET_KEYBOARD_MODIFIERS returns {alt,shift,cmd,ctrl} booleans, all false at rest")
print("✅ test_keyboard_modifiers_binding passed")
