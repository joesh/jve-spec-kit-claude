--- Keyboard constants: Qt key codes and modifier flags.
--
-- Extracted from keyboard_shortcuts.lua to break circular dependency
-- between keyboard_shortcuts and keyboard_shortcut_registry.
--
-- @file keyboard_constants.lua
local M = {}

-- Qt key constants (from Qt::Key enum)
M.KEY = {
    Space = 32,
    Backspace = 16777219,
    Delete = 16777223,
    Left = 16777234,
    Right = 16777236,
    Up = 16777235,
    Down = 16777237,
    Home = 16777232,
    End = 16777233,
    A = 65,
    C = 67,
    N = 78,
    V = 86,
    X = 88,
    Z = 90,
    I = 73,
    O = 79,
    B = 66,
    J = 74,
    K = 75,
    L = 76,
    M = 77,
    Q = 81,
    W = 87,
    E = 69,
    R = 82,
    T = 84,
    Key2 = 50,
    Key3 = 51,
    Key4 = 52,
    Plus = 43,       -- '+'
    Minus = 45,      -- '-'
    Equal = 61,      -- '=' (also + on US keyboards)
    Comma = 44,      -- ','
    Period = 46,     -- '.'
    Grave = 96,      -- '`' (backtick)
    Tilde = 126,     -- '~'
    F1 = 16777264,   -- 0x01000030
    F2 = 16777265,   -- 0x01000031
    F9 = 16777272,   -- 0x01000038
    F10 = 16777273,  -- 0x01000039
    F11 = 16777274,  -- 0x0100003A
    F12 = 16777275,  -- 0x0100003B
    Return = 16777220,
    Enter = 16777221,
    Escape = 16777216,
    Tab = 16777217,
    BracketLeft = 91,   -- '[' (Qt::Key_BracketLeft)
    BracketRight = 93,  -- ']' (Qt::Key_BracketRight)
    BraceLeft = 123,    -- '{' (Qt::Key_BraceLeft) — Shift+[
    BraceRight = 125,   -- '}' (Qt::Key_BraceRight) — Shift+]
}

-- Qt modifier constants (from Qt::KeyboardModifier enum)
M.MOD = {
    NoModifier = 0,
    Shift = 0x02000000,
    Control = 0x04000000,
    Alt = 0x08000000,
    Meta = 0x10000000,
    Keypad = 0x20000000,
}

-- Mask of modifiers significant for shortcut matching.
-- Strips KeypadModifier (0x20000000) and GroupSwitchModifier (0x40000000)
-- which Qt adds to arrow keys, numpad keys, etc.
M.SIGNIFICANT_MOD_MASK = 0x1E000000  -- Shift | Control | Alt | Meta

-- Qt6 shifted-symbol normalization (US keyboard layout).
--
-- Canonical form: UNSHIFTED key code + Shift modifier (if shift was involved).
-- All three notations normalize to the same combo_key:
--   "Tilde"        → key=Grave(96), mod=Shift     (shifted name is sugar; demoted + Shift added)
--   "Shift+Grave"  → key=Grave(96), mod=Shift     (already canonical)
--   "Shift+Tilde"  → key=Grave(96), mod=Shift     (demoted; Shift kept)
-- At runtime Qt sends key=Tilde(126)+Shift for Shift+`; handle_key_event
-- demotes the key to Grave and preserves Shift.
--
-- Why this form: Shift is preserved as a first-class modifier, so bindings
-- that differ only in Shift (e.g. Cmd+Equal vs Cmd+Shift+Equal) are naturally
-- distinguishable. Keypad keys (Plus, etc.) arrive WITHOUT Shift and are NOT
-- demoted, so keypad bindings stay independent from Shift+Equal-style bindings.

-- shifted_key_code → unshifted_key_code: demote at parse time and at runtime.
-- A missing entry means the key has no shift variant (or the demotion is
-- layout-specific and not supported).
M.SHIFTED_TO_UNSHIFTED = {
    [43]  = 61,   -- Plus (+)         → Equal (=)
    [126] = 96,   -- Tilde (~)        → Grave (`)
    [123] = 91,   -- BraceLeft ({)    → BracketLeft ([)
    [125] = 93,   -- BraceRight (})   → BracketRight (])
    [60]  = 44,   -- Less (<)         → Comma (,)
    [62]  = 46,   -- Greater (>)      → Period (.)
    [95]  = 45,   -- Underscore (_)   → Minus (-)
    [63]  = 47,   -- Question (?)     → Slash (/)
    [58]  = 59,   -- Colon (:)        → Semicolon (;)
    [34]  = 39,   -- QuoteDbl (")     → Apostrophe (')
    [124] = 92,   -- Bar (|)          → Backslash (\)
    [41]  = 48,   -- ParenRight ())   → 0
    [33]  = 49,   -- Exclam (!)       → 1
    [64]  = 50,   -- At (@)           → 2
    [35]  = 51,   -- NumberSign (#)   → 3
    [36]  = 52,   -- Dollar ($)       → 4
    [37]  = 53,   -- Percent (%)      → 5
    [94]  = 54,   -- AsciiCircum (^)  → 6
    [38]  = 55,   -- Ampersand (&)    → 7
    [42]  = 56,   -- Asterisk (*)     → 8
    [40]  = 57,   -- ParenLeft (()    → 9
}

-- Inverse mapping for human-readable display: a canonical (unshifted_key,
-- Shift) pair is presented as the shifted glyph alone, since the glyph
-- already encodes Shift on a QWERTY layout. E.g. format_shortcut(2, Shift)
-- → "@" rather than "Shift+2"; Ctrl+Shift+/ → "Ctrl+?".
M.UNSHIFTED_TO_SHIFTED = {}
for shifted, unshifted in pairs(M.SHIFTED_TO_UNSHIFTED) do
    M.UNSHIFTED_TO_SHIFTED[unshifted] = shifted
end

return M
