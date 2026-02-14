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
    F2 = 16777249,   -- 0x01000031
    F9 = 16777272,   -- 0x01000038
    F10 = 16777273,  -- 0x01000039
    F12 = 16777275,  -- 0x0100003B
    Return = 16777220,
    Enter = 16777221,
    Tab = 16777217,
    BracketLeft = 91,   -- '[' (Qt::Key_BracketLeft)
    BracketRight = 93,  -- ']' (Qt::Key_BracketRight)
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

return M
