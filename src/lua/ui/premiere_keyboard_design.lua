--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~127 LOC
-- Volatility: unknown
--
-- @file premiere_keyboard_design.lua
-- Original intent (unreviewed):
-- Premiere keyboard geometry normalized for JVE layout.
-- Each row defines physical widths (Premiere pixels) and gaps before the key.
return {
    {
        id = "function",
        row_gap_px = 130,
        row_height_px = 120,
        keys = {
            {label = "Help", key = "Help", width_px = 437, gap_before_px = 32},
            {label = "F1",   key = "F1",   width_px = 129, gap_before_px = 83},
            {label = "F2",   key = "F2",   width_px = 129, gap_before_px = 6},
            {label = "F3",   key = "F3",   width_px = 129, gap_before_px = 7},
            {label = "F4",   key = "F4",   width_px = 129, gap_before_px = 7},
            {label = "F5",   key = "F5",   width_px = 129, gap_before_px = 7},
            {label = "F6",   key = "F6",   width_px = 129, gap_before_px = 5},
            {label = "F7",   key = "F7",   width_px = 129, gap_before_px = 7},
            {label = "F8",   key = "F8",   width_px = 129, gap_before_px = 5},
            {label = "F9",   key = "F9",   width_px = 129, gap_before_px = 5},
            {label = "F10",  key = "F10",  width_px = 129, gap_before_px = 4},
            {label = "F11",  key = "F11",  width_px = 129, gap_before_px = 8},
            {label = "F12",  key = "F12",  width_px = 129, gap_before_px = 8},
        },
    },
    {
        id = "number",
        row_gap_px = 130,
        row_height_px = 120,
        keys = {
            {label = "`", key = "Grave", width_px = 102, gap_before_px = 32},
            {label = "1", key = "1",     width_px = 102, gap_before_px = 7},
            {label = "2", key = "2",     width_px = 102, gap_before_px = 6},
            {label = "3", key = "3",     width_px = 102, gap_before_px = 8},
            {label = "4", key = "4",     width_px = 102, gap_before_px = 6},
            {label = "5", key = "5",     width_px = 102, gap_before_px = 7},
            {label = "6", key = "6",     width_px = 102, gap_before_px = 8},
            {label = "7", key = "7",     width_px = 102, gap_before_px = 7},
            {label = "8", key = "8",     width_px = 102, gap_before_px = 7},
            {label = "9", key = "9",     width_px = 102, gap_before_px = 6},
            {label = "0", key = "0",     width_px = 101, gap_before_px = 8},
            {label = "-", key = "Minus", width_px = 101, gap_before_px = 8},
            {label = "=", key = "Equal", width_px = 101, gap_before_px = 8},
            {label = "Backspace", key = "Backspace", width_px = 192, gap_before_px = 9},
            {label = "Insert",   key = "Insert",    width_px = 102, gap_before_px = 170},
            {label = "Home",     key = "Home",      width_px = 102, gap_before_px = 7},
            {label = "PgUp",     key = "PageUp",    width_px = 102, gap_before_px = 7},
        },
    },
    {
        id = "tab",
        row_gap_px = 130,
        row_height_px = 120,
        keys = {
            {label = "Tab", key = "Tab", width_px = 193, gap_before_px = 32},
            {label = "Q", key = "Q", width_px = 102, gap_before_px = 7},
            {label = "W", key = "W", width_px = 102, gap_before_px = 6},
            {label = "E", key = "E", width_px = 102, gap_before_px = 8},
            {label = "R", key = "R", width_px = 102, gap_before_px = 6},
            {label = "T", key = "T", width_px = 102, gap_before_px = 7},
            {label = "Y", key = "Y", width_px = 102, gap_before_px = 8},
            {label = "U", key = "U", width_px = 102, gap_before_px = 7},
            {label = "I", key = "I", width_px = 102, gap_before_px = 6},
            {label = "O", key = "O", width_px = 102, gap_before_px = 8},
            {label = "P", key = "P", width_px = 102, gap_before_px = 7},
            {label = "[", key = "BracketLeft", width_px = 102, gap_before_px = 7},
            {label = "]", key = "BracketRight", width_px = 102, gap_before_px = 7},
            {label = "\\", key = "Backslash", width_px = 102, gap_before_px = 6},
            {label = "Delete", key = "Delete", width_px = 102, gap_before_px = 62},
            {label = "End",    key = "End",    width_px = 102, gap_before_px = 7},
            {label = "PgDn",   key = "PageDown", width_px = 102, gap_before_px = 7},
        },
    },
    {
        id = "caps",
        row_gap_px = 130,
        row_height_px = 120,
        keys = {
            {label = "Caps", key = "CapsLock", width_px = 203, gap_before_px = 33},
            {label = "A", key = "A", width_px = 102, gap_before_px = 4},
            {label = "S", key = "S", width_px = 102, gap_before_px = 8},
            {label = "D", key = "D", width_px = 102, gap_before_px = 6},
            {label = "F", key = "F", width_px = 102, gap_before_px = 7},
            {label = "G", key = "G", width_px = 102, gap_before_px = 8},
            {label = "H", key = "H", width_px = 102, gap_before_px = 7},
            {label = "J", key = "J", width_px = 102, gap_before_px = 7},
            {label = "K", key = "K", width_px = 102, gap_before_px = 6},
            {label = "L", key = "L", width_px = 102, gap_before_px = 7},
            {label = ";", key = "Semicolon", width_px = 102, gap_before_px = 7},
            {label = "'", key = "Apostrophe", width_px = 102, gap_before_px = 7},
            {label = "Return", key = "Return", width_px = 202, gap_before_px = 9},
        },
    },
    {
        id = "shift",
        row_gap_px = 130,
        row_height_px = 120,
        keys = {
            {label = "Shift", key = "Shift", width_px = 257, gap_before_px = 32},
            {label = "Z", key = "Z", width_px = 101, gap_before_px = 6},
            {label = "X", key = "X", width_px = 101, gap_before_px = 9},
            {label = "C", key = "C", width_px = 101, gap_before_px = 8},
            {label = "V", key = "V", width_px = 101, gap_before_px = 7},
            {label = "B", key = "B", width_px = 102, gap_before_px = 8},
            {label = "N", key = "N", width_px = 102, gap_before_px = 8},
            {label = "M", key = "M", width_px = 102, gap_before_px = 7},
            {label = ",", key = "Comma", width_px = 102, gap_before_px = 6},
            {label = ".", key = "Period", width_px = 102, gap_before_px = 7},
            {label = "/", key = "Slash", width_px = 102, gap_before_px = 7},
            {label = "Shift", key = "Shift", width_px = 258, gap_before_px = 7},
            {label = "Up", key = "Up", width_px = 101, gap_before_px = 171},
        },
    },
    {
        id = "space",
        row_gap_px = 160,
        row_height_px = 140,
        keys = {
            {label = "Ctrl", key = "Ctrl", width_px = 152, gap_before_px = 26},
            {label = "Opt", key = "Option", width_px = 101, gap_before_px = 8},
            {label = "Cmd", key = "Command", width_px = 152, gap_before_px = 8},
            {label = "Space", key = "Space", width_px = 755, gap_before_px = 7},
            {label = "Cmd", key = "Command", width_px = 152, gap_before_px = 7},
            {label = "Opt", key = "Option", width_px = 102, gap_before_px = 7},
            {label = "Ctrl", key = "Ctrl", width_px = 153, gap_before_px = 8},
            {label = "Left", key = "Left", width_px = 101, gap_before_px = 61},
            {label = "Down", key = "Down", width_px = 101, gap_before_px = 8},
            {label = "Right", key = "Right", width_px = 101, gap_before_px = 8},
        },
    },
}
