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
-- Canonical form: shifted key code, NO Shift modifier.
-- All three notations normalize to the same combo_key:
--   "Tilde"        → key=126, mod=0        (already canonical)
--   "Shift+Grave"  → key=126, mod=0        (parse_shortcut promotes key, strips Shift)
--   "Shift+Tilde"  → key=126, mod=0        (parse_shortcut strips redundant Shift)
-- At runtime Qt sends key=126+Shift; handle_key_event strips Shift.

-- shifted_key_code → true: strip Shift at runtime and parse time
M.SHIFTED_SYMBOL_KEYS = {
    [43]  = true,  -- Plus (+)
    [126] = true,  -- Tilde (~)
    [33]  = true,  -- Exclam (!)
    [64]  = true,  -- At (@)
    [35]  = true,  -- NumberSign (#)
    [36]  = true,  -- Dollar ($)
    [37]  = true,  -- Percent (%)
    [94]  = true,  -- AsciiCircum (^)
    [38]  = true,  -- Ampersand (&)
    [42]  = true,  -- Asterisk (*)
    [40]  = true,  -- ParenLeft (()
    [41]  = true,  -- ParenRight ())
    [95]  = true,  -- Underscore (_)
    [123] = true,  -- BraceLeft ({)
    [125] = true,  -- BraceRight (})
    [124] = true,  -- Bar (|)
    [58]  = true,  -- Colon (:)
    [34]  = true,  -- QuoteDbl (")
    [60]  = true,  -- Less (<)
    [62]  = true,  -- Greater (>)
    [63]  = true,  -- Question (?)
}

-- unshifted_key_code → shifted_key_code: promote Shift+unshifted at parse time
M.UNSHIFTED_TO_SHIFTED = {
    [96]  = 126,   -- Grave (`)    → Tilde (~)
    [91]  = 123,   -- BracketLeft  → BraceLeft
    [93]  = 125,   -- BracketRight → BraceRight
    [44]  = 60,    -- Comma        → Less
    [46]  = 62,    -- Period       → Greater
    [45]  = 95,    -- Minus        → Underscore
    [61]  = 43,    -- Equal        → Plus
    [47]  = 63,    -- Slash        → Question
    [59]  = 58,    -- Semicolon    → Colon
    [39]  = 34,    -- Apostrophe   → QuoteDbl
    [92]  = 124,   -- Backslash    → Bar
    [48]  = 41,    -- 0            → ParenRight
    [49]  = 33,    -- 1            → Exclam
    [50]  = 64,    -- 2            → At
    [51]  = 35,    -- 3            → NumberSign
    [52]  = 36,    -- 4            → Dollar
    [53]  = 37,    -- 5            → Percent
    [54]  = 94,    -- 6            → AsciiCircum
    [55]  = 38,    -- 7            → Ampersand
    [56]  = 42,    -- 8            → Asterisk
    [57]  = 40,    -- 9            → ParenLeft
}

return M
