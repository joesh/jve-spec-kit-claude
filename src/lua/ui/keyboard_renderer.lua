-- Visual Keyboard Renderer (Pure Lua)
-- Faithful rendering of physical keyboard layout for shortcut visualization
-- Matches Premiere Pro visual style

local M = {}

local qt = require('qt_bindings')

-- Premiere Pro color scheme
local COLORS = {
    -- Key colors
    KEY_BG = "#2d2d30",              -- Normal key background
    KEY_BG_MODIFIER = "#3e3e42",     -- Modifier keys (Shift, Ctrl, etc.)
    KEY_BG_FUNCTION = "#1e1e1e",     -- Function keys (F1-F12)
    KEY_TEXT = "#e8e8e8",            -- Key label text
    KEY_BORDER = "#3f3f46",          -- Key border
    KEY_ASSIGNED = "#094771",        -- Key with shortcut assigned (Premiere blue)
    KEY_HOVER = "#3e3e42",           -- Key hover state

    -- Layout colors
    KEYBOARD_BG = "#1e1e1e",         -- Background behind keyboard
    SECTION_DIVIDER = "#3f3f46",     -- Lines between key sections

    -- Accent colors
    ACCENT_BLUE = "#0078d4",         -- Active/selected keys
    ACCENT_ORANGE = "#f48771",       -- Conflicts/warnings
}

-- Key size constants (in pixels)
local KEY_SIZE = {
    STANDARD_WIDTH = 48,
    STANDARD_HEIGHT = 48,
    SPACING = 4,                     -- Gap between keys

    -- Special key widths (multiples of standard + spacing)
    TAB = 72,                        -- 1.5x
    CAPS = 86,                       -- 1.75x
    SHIFT_LEFT = 110,                -- 2.25x
    SHIFT_RIGHT = 134,               -- 2.75x
    CTRL = 72,                       -- 1.5x
    ALT = 62,                        -- 1.25x
    CMD = 72,                        -- 1.5x (Mac) / Win key
    SPACE = 290,                     -- 6x
    ENTER = 110,                     -- 2.25x
    BACKSPACE = 96,                  -- 2x
}

-- Keyboard layout definition (US QWERTY)
-- Each key: {label, width, key_type}
-- key_type: "normal", "modifier", "function"

local KEYBOARD_LAYOUT = {
    -- Function row
    {
        {label = "Esc", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "", width = KEY_SIZE.STANDARD_WIDTH, type = "spacer"},  -- Gap
        {label = "F1", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "F2", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "F3", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "F4", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "", width = KEY_SIZE.SPACING * 2, type = "spacer"},
        {label = "F5", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "F6", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "F7", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "F8", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "", width = KEY_SIZE.SPACING * 2, type = "spacer"},
        {label = "F9", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "F10", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "F11", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
        {label = "F12", width = KEY_SIZE.STANDARD_WIDTH, type = "function"},
    },

    -- Number row
    {
        {label = "`", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "1", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "2", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "3", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "4", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "5", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "6", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "7", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "8", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "9", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "0", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "-", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "=", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "Backspace", width = KEY_SIZE.BACKSPACE, type = "modifier"},
    },

    -- QWERTY row
    {
        {label = "Tab", width = KEY_SIZE.TAB, type = "modifier"},
        {label = "Q", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "W", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "E", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "R", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "T", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "Y", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "U", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "I", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "O", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "P", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "[", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "]", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "\\", width = KEY_SIZE.TAB, type = "normal"},
    },

    -- ASDF row
    {
        {label = "Caps", width = KEY_SIZE.CAPS, type = "modifier"},
        {label = "A", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "S", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "D", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "F", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "G", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "H", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "J", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "K", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "L", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = ";", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "'", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "Enter", width = KEY_SIZE.ENTER, type = "modifier"},
    },

    -- ZXCV row
    {
        {label = "Shift", width = KEY_SIZE.SHIFT_LEFT, type = "modifier"},
        {label = "Z", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "X", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "C", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "V", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "B", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "N", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "M", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = ",", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = ".", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "/", width = KEY_SIZE.STANDARD_WIDTH, type = "normal"},
        {label = "Shift", width = KEY_SIZE.SHIFT_RIGHT, type = "modifier"},
    },

    -- Bottom row
    {
        {label = "Ctrl", width = KEY_SIZE.CTRL, type = "modifier"},
        {label = "Alt", width = KEY_SIZE.ALT, type = "modifier"},
        {label = "Cmd", width = KEY_SIZE.CMD, type = "modifier"},
        {label = "Space", width = KEY_SIZE.SPACE, type = "normal"},
        {label = "Cmd", width = KEY_SIZE.CMD, type = "modifier"},
        {label = "Alt", width = KEY_SIZE.ALT, type = "modifier"},
        {label = "Ctrl", width = KEY_SIZE.CTRL, type = "modifier"},
    },
}

-- Key state tracking (for assigned shortcuts, hover, etc.)
local key_states = {}  -- key_label -> {assigned = bool, hover = bool}

-- Create the keyboard widget
function M.create()
    -- Main container widget
    local keyboard_widget = qt.CREATE_MAIN_WINDOW()

    -- Calculate total keyboard dimensions
    local max_row_width = 0
    local total_height = 0

    for _, row in ipairs(KEYBOARD_LAYOUT) do
        local row_width = 0
        for _, key in ipairs(row) do
            row_width = row_width + key.width + KEY_SIZE.SPACING
        end
        max_row_width = math.max(max_row_width, row_width)
        total_height = total_height + KEY_SIZE.STANDARD_HEIGHT + KEY_SIZE.SPACING
    end

    -- Add padding
    local padding = 20
    max_row_width = max_row_width + padding * 2
    total_height = total_height + padding * 2

    qt.SET_SIZE(keyboard_widget, max_row_width, total_height)
    qt.SET_WIDGET_STYLESHEET(keyboard_widget, string.format([[
        QWidget {
            background-color: %s;
        }
    ]], COLORS.KEYBOARD_BG))

    -- Main layout
	    local main_layout = qt.CREATE_VBOX()

	    -- Create each row
	    for row_idx, row in ipairs(KEYBOARD_LAYOUT) do
	        local row_layout = qt.CREATE_HBOX()
	        qt.SET_LAYOUT_SPACING(row_layout, KEY_SIZE.SPACING)

        -- Add left padding for centered alignment
        qt.ADD_STRETCH(row_layout)

        -- Create keys for this row
        for key_idx, key in ipairs(row) do
            if key.type == "spacer" then
                -- Empty space (gap between key groups)
                local spacer = qt.CREATE_LABEL()
                qt.SET_MINIMUM_WIDTH(spacer, key.width)
                qt.ADD_WIDGET(row_layout, spacer)
            else
                -- Actual key button
                local key_button = M.create_key(key.label, key.width, key.type)
                qt.ADD_WIDGET(row_layout, key_button)
            end
        end

        -- Add right padding
        qt.ADD_STRETCH(row_layout)

        -- Add row to main layout
        qt.ADD_LAYOUT(main_layout, row_layout)
    end

    -- Add bottom padding
    qt.ADD_STRETCH(main_layout)

    qt.SET_LAYOUT(keyboard_widget, main_layout)

    return keyboard_widget
end

-- Create a single key button
function M.create_key(label, width, key_type)
    local key_button = qt.CREATE_BUTTON()
    qt.SET_TEXT(key_button, label)
    qt.SET_MINIMUM_SIZE(key_button, width, KEY_SIZE.STANDARD_HEIGHT)
    qt.SET_MAXIMUM_SIZE(key_button, width, KEY_SIZE.STANDARD_HEIGHT)

    -- Determine background color based on key type
    local bg_color = COLORS.KEY_BG
    if key_type == "modifier" then
        bg_color = COLORS.KEY_BG_MODIFIER
    elseif key_type == "function" then
        bg_color = COLORS.KEY_BG_FUNCTION
    end

    -- Check if this key has a shortcut assigned
    local state = key_states[label] or {}
    if state.assigned then
        bg_color = COLORS.KEY_ASSIGNED
    end

    -- Apply styling
    qt.SET_WIDGET_STYLESHEET(key_button, string.format([[
        QPushButton {
            background-color: %s;
            color: %s;
            border: 1px solid %s;
            border-radius: 4px;
            font-size: 12px;
            font-weight: normal;
            padding: 4px;
        }
        QPushButton:hover {
            background-color: %s;
            border: 1px solid %s;
        }
        QPushButton:pressed {
            background-color: %s;
        }
    ]], bg_color, COLORS.KEY_TEXT, COLORS.KEY_BORDER,
        COLORS.KEY_HOVER, COLORS.ACCENT_BLUE,
        COLORS.ACCENT_BLUE))

    -- Click handler (for future interaction)
    qt.SET_BUTTON_CLICKED_HANDLER(key_button, function()
        M.on_key_clicked(label)
    end)

    return key_button
end

-- Handle key click
function M.on_key_clicked(key_label)
    print(string.format("Key clicked: %s", key_label))
    -- Future: Show shortcuts assigned to this key
    -- Future: Allow assigning new shortcut
end

-- Mark a key as having a shortcut assigned
function M.mark_key_assigned(key_label, assigned)
    if not key_states[key_label] then
        key_states[key_label] = {}
    end
    key_states[key_label].assigned = assigned
    -- TODO: Update visual appearance
end

-- Get all keys that have shortcuts assigned
function M.get_assigned_keys()
    local assigned = {}
    for label, state in pairs(key_states) do
        if state.assigned then
            table.insert(assigned, label)
        end
    end
    return assigned
end

-- Clear all key states
function M.clear_key_states()
    key_states = {}
end

-- Show the keyboard in a window
function M.show()
    local keyboard = M.create()
    qt.SHOW_WINDOW(keyboard)
    return keyboard
end

return M
