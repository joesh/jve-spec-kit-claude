--- Keyboard picture: Premiere-style visual QWERTY layout
--
-- Responsibilities:
-- - Render a fixed-layout keyboard (function row + alphanumerics + modifiers)
-- - For each tile, look up the command bound under the current modifier mask
--   and color the tile (purple = global, green = panel-scoped, both = split)
-- - Modifier tiles (Shift/Cmd/Opt/Ctrl) are clickable toggles that re-render
--   the keyboard with that modifier set added/removed
-- - Non-modifier tiles fire opts.on_key_click(key_code, modifiers) so the
--   command table below can filter to bindings on that key
--
-- Non-goals:
-- - Numpad / arrow island (defer until needed; main keyboard covers all
--   typically-bound keys)
-- - Per-OS keyboard layouts (US ANSI only — Premiere also defaults to en)
--
-- @file keyboard_picture.lua
local M = {}

local qt_constants = require('core.qt_constants')
local kb_constants = require('core.keyboard_constants')
local registry = require('core.keyboard_shortcut_registry')
local ui_constants = require('core.ui_constants')
local bit = require('bit')

local WIDGET = qt_constants.WIDGET
local LAYOUT = qt_constants.LAYOUT
local PROP = qt_constants.PROPERTIES
local CONTROL = qt_constants.CONTROL

-- Tile geometry — measured from Premiere's keyboard panel.
-- Standard ANSI layout is 15 units wide (` + 10 digits + 2 punct + Backspace=2
-- on the number row; Tab=1.5 + 10 letters + [=] + \=1.5 on Q row; etc.).
-- Premiere's cells are roughly square at ~72px per unit. Command label lives
-- at the TOP of the tile; key-name stays at the BOTTOM as a small badge.
local STD_W = 72
local CELL_H = 72

-- Resolve a key name or single character to a Qt key code. Used at
-- layout-construction time; layout keys come from a small fixed vocabulary
-- so we don't need a robust parser — just KEY-table or ASCII fallback.
-- Qt::Key_F1 = 0x01000030; F-keys are sequential.
local QT_KEY_F1 = 16777264

local function K(name)
    local code = kb_constants.KEY[name]
    if code then return code end
    -- F-keys: derive from the F number (kb_constants only ships F1/F2/F9-F12)
    local f_num = name:match("^F(%d+)$")
    if f_num then
        local n = tonumber(f_num)
        if n and n >= 1 and n <= 35 then
            return QT_KEY_F1 + (n - 1)
        end
    end
    assert(#name == 1, "keyboard_picture: unknown key '" .. name .. "'")
    return string.byte(name:upper())
end

-- Modifier mask helper
local MOD = kb_constants.MOD
local MOD_FOR = {
    Shift = MOD.Shift,
    Cmd   = MOD.Control,  -- macOS Qt: Cmd = ControlModifier
    Alt   = MOD.Alt,
    Ctrl  = MOD.Meta,     -- macOS Qt: physical Ctrl = MetaModifier
}

-- Layout — each row is an array of cells.
--   regular cell: {key=code, label=str, w=units}
--   modifier:     {mod="Shift|Cmd|Alt|Ctrl", label=str, w=units}
--   spacer:       {gap=units}
local function build_layout()
    return {
        -- Function row
        {
            {key=K("Escape"), label="Esc", w=1.0},
            {gap=0.5},
            {key=K("F1"), label="F1", w=1.0}, {key=K("F2"), label="F2", w=1.0},
            {key=K("F3"), label="F3", w=1.0}, {key=K("F4"), label="F4", w=1.0},
            {gap=0.25},
            {key=K("F5"), label="F5", w=1.0}, {key=K("F6"), label="F6", w=1.0},
            {key=K("F7"), label="F7", w=1.0}, {key=K("F8"), label="F8", w=1.0},
            {gap=0.25},
            {key=K("F9"), label="F9", w=1.0}, {key=K("F10"), label="F10", w=1.0},
            {key=K("F11"), label="F11", w=1.0}, {key=K("F12"), label="F12", w=1.0},
        },
        -- Number row
        {
            {key=K("Grave"), label="`", w=1.0},
            {key=string.byte("1"), label="1", w=1.0},
            {key=string.byte("2"), label="2", w=1.0},
            {key=string.byte("3"), label="3", w=1.0},
            {key=string.byte("4"), label="4", w=1.0},
            {key=string.byte("5"), label="5", w=1.0},
            {key=string.byte("6"), label="6", w=1.0},
            {key=string.byte("7"), label="7", w=1.0},
            {key=string.byte("8"), label="8", w=1.0},
            {key=string.byte("9"), label="9", w=1.0},
            {key=string.byte("0"), label="0", w=1.0},
            {key=K("Minus"), label="-", w=1.0},
            {key=K("Equal"), label="=", w=1.0},
            {key=K("Backspace"), label="⌫", w=2.0},
        },
        -- Top letter row
        {
            {key=K("Tab"), label="Tab", w=1.5},
            {key=K("Q"), label="Q", w=1.0}, {key=K("W"), label="W", w=1.0},
            {key=K("E"), label="E", w=1.0}, {key=K("R"), label="R", w=1.0},
            {key=K("T"), label="T", w=1.0}, {key=K("Y"), label="Y", w=1.0},
            {key=K("U"), label="U", w=1.0}, {key=K("I"), label="I", w=1.0},
            {key=K("O"), label="O", w=1.0}, {key=K("P"), label="P", w=1.0},
            {key=K("BracketLeft"),  label="[", w=1.0},
            {key=K("BracketRight"), label="]", w=1.0},
            {key=string.byte("\\"), label="\\", w=1.5},
        },
        -- Home letter row (Caps Lock is intentionally inert — no key code,
        -- gray placeholder so the row geometry matches a real keyboard)
        {
            {placeholder=true, label="Caps", w=1.75},
            {key=K("A"), label="A", w=1.0}, {key=K("S"), label="S", w=1.0},
            {key=K("D"), label="D", w=1.0}, {key=K("F"), label="F", w=1.0},
            {key=K("G"), label="G", w=1.0}, {key=K("H"), label="H", w=1.0},
            {key=K("J"), label="J", w=1.0}, {key=K("K"), label="K", w=1.0},
            {key=K("L"), label="L", w=1.0},
            {key=string.byte(";"), label=";", w=1.0},
            {key=string.byte("'"), label="'", w=1.0},
            {key=K("Return"), label="Return", w=2.25},
        },
        -- Bottom letter row
        {
            {mod="Shift", label="⇧ Shift", w=2.25},
            {key=K("Z"), label="Z", w=1.0}, {key=K("X"), label="X", w=1.0},
            {key=K("C"), label="C", w=1.0}, {key=K("V"), label="V", w=1.0},
            {key=K("B"), label="B", w=1.0}, {key=K("N"), label="N", w=1.0},
            {key=K("M"), label="M", w=1.0},
            {key=K("Comma"),  label=",", w=1.0},
            {key=K("Period"), label=".", w=1.0},
            {key=string.byte("/"), label="/", w=1.0},
            {mod="Shift", label="⇧ Shift", w=2.75},
        },
        -- Modifier + Space
        {
            {mod="Ctrl", label="^ Ctrl", w=1.25},
            {mod="Alt",  label="⌥ Opt",  w=1.25},
            {mod="Cmd",  label="⌘ Cmd",  w=1.25},
            {key=K("Space"), label="Space", w=6.25},
            {mod="Cmd",  label="⌘ Cmd",  w=1.25},
            {mod="Alt",  label="⌥ Opt",  w=1.25},
            {mod="Ctrl", label="^ Ctrl", w=1.25},
        },
    }
end

-- ---- Color logic --------------------------------------------------------
-- Look up bindings for (key, modifiers); return {has_global, has_panel, command_label}
local function lookup_binding(key, modifiers)
    local combo_key = string.format("%d_%d", key, modifiers)
    local bindings = registry.keybindings[combo_key]
    if not bindings or #bindings == 0 then return nil end
    local has_global, has_panel = false, false
    local first_label
    for _, b in ipairs(bindings) do
        if not b.contexts or #b.contexts == 0 then
            has_global = true
        else
            has_panel = true
        end
        if not first_label then
            local cmd = registry.commands[b.command_name]
            assert(cmd, "keyboard_picture: binding references unregistered command '"
                .. tostring(b.command_name) .. "'")
            first_label = cmd.name
        end
    end
    return { has_global = has_global, has_panel = has_panel, label = first_label }
end

-- Generate stylesheet for a tile based on its binding state.
-- Premiere palette: purple = global, green = panel-scoped.
-- Selected tiles get a thick blue outline (click or physical press).
local function tile_style(state)
    local C = ui_constants.COLORS
    local bg, border = C.KEY_HOVER, C.KEY_BORDER
    local border_width = 1
    if state.placeholder then
        bg, border = C.CONTROL_INACTIVE_BG, C.KEY_HOVER
    elseif state.modifier_active then
        bg, border = C.KEY_MOD_PRESSED_BG, C.KEY_MOD_PRESSED_BORDER  -- blue when modifier currently pressed
    elseif state.modifier then
        bg, border = C.KEY_BG_MODIFIER, C.KEY_BORDER_LIGHT     -- modifier tile, idle
    elseif state.binding then
        if state.binding.has_global and state.binding.has_panel then
            bg, border = C.KEY_PURPLE_BG, C.KEY_PURPLE_BORDER
        elseif state.binding.has_global then
            bg, border = C.KEY_PURPLE_BG, C.KEY_PURPLE_BORDER  -- purple
        else
            bg, border = C.KEY_GREEN_BG, C.KEY_GREEN_BORDER  -- green
        end
    end
    if state.selected then
        border = C.KEY_SELECT_OUTLINE  -- cyan-blue selection outline
        border_width = 2
    end
    return string.format(
        "QWidget { background-color: %s; border: %dpx solid %s; "
        .. "border-radius: 4px; }"
        .. "QLabel { color: %s; background: transparent; "
        .. "border: none; }",
        bg, border_width, border, C.TEXT_HEADING)
end

-- ---- Tile builder -------------------------------------------------------
local handler_seq = 0
local function register_handler(callback)
    handler_seq = handler_seq + 1
    local name = string.format("__keyboard_picture_handler_%d", handler_seq)
    _G[name] = function(...) callback(...) end
    return name
end

-- A tile is a fixed-size container with two stacked labels: key name (top,
-- small) and command label (below, smaller). Both labels live so we can
-- update text without rebuilding the widget on every modifier change.
local function build_tile(cell)
    local tile = WIDGET.CREATE()
    PROP.SET_MIN_WIDTH(tile, math.floor(STD_W * cell.w))
    PROP.SET_MAX_WIDTH(tile, math.floor(STD_W * cell.w))
    PROP.SET_MIN_HEIGHT(tile, CELL_H)
    PROP.SET_MAX_HEIGHT(tile, CELL_H)

    -- Premiere stacks the command name on TOP (where the eye lands) and the
    -- key name at the BOTTOM as a small subdued badge. Mirror that.
    local layout = LAYOUT.CREATE_VBOX()
    LAYOUT.SET_MARGINS(layout, 4, 4, 4, 4)
    LAYOUT.SET_SPACING(layout, 0)

    local cmd_label = WIDGET.CREATE_LABEL("")
    PROP.SET_STYLE(cmd_label, string.format("QLabel { font-size: 10px; color: %s; font-weight: 600; }", ui_constants.COLORS.TEXT_PRIMARY))
    -- Allow the command text to wrap onto a second line — long names like
    -- "Rolling Edit Tool" or "Trim Backward" otherwise clip to useless stubs.
    CONTROL.SET_WORD_WRAP(cmd_label, true)
    LAYOUT.ADD_WIDGET(layout, cmd_label)

    LAYOUT.ADD_STRETCH(layout, 1)

    assert(cell.label,
        "keyboard_picture: cell missing required 'label' field")
    local key_label = WIDGET.CREATE_LABEL(cell.label)
    PROP.SET_STYLE(key_label, string.format("QLabel { font-size: 11px; color: %s; font-weight: 500; }", ui_constants.COLORS.KEY_SUBLABEL_TEXT))
    LAYOUT.ADD_WIDGET(layout, key_label)

    LAYOUT.SET_ON_WIDGET(tile, layout)

    return { widget = tile, cmd_label = cmd_label }
end

-- ---- Public API ---------------------------------------------------------

-- opts: { on_key_click = function(key_code, modifiers) }
-- Returns a table { widget, refresh, set_modifiers, get_modifiers, modifiers (read-only) }
function M.create(opts)
    opts = opts or {}

    local container = WIDGET.CREATE()
    local outer = LAYOUT.CREATE_VBOX()
    LAYOUT.SET_MARGINS(outer, 4, 4, 4, 4)
    LAYOUT.SET_SPACING(outer, 4)

    local tiles = {}  -- list of { tile, cell }
    local state = {
        modifiers = 0,
        selected_key = nil,  -- Qt key code of the currently-highlighted tile
    }

    for _, row in ipairs(build_layout()) do
        local hbox = LAYOUT.CREATE_HBOX()
        LAYOUT.SET_SPACING(hbox, 4)
        for _, cell in ipairs(row) do
            if cell.gap then
                -- Fixed gap: invisible spacer of the requested width
                local sp = WIDGET.CREATE()
                PROP.SET_MIN_WIDTH(sp, math.floor(STD_W * cell.gap))
                PROP.SET_MAX_WIDTH(sp, math.floor(STD_W * cell.gap))
                LAYOUT.ADD_WIDGET(hbox, sp)
            else
                local tile = build_tile(cell)
                LAYOUT.ADD_WIDGET(hbox, tile.widget)
                tiles[#tiles + 1] = { tile = tile, cell = cell }
            end
        end
        LAYOUT.ADD_STRETCH(hbox, 1)  -- right-justify slack
        local row_widget = WIDGET.CREATE()
        LAYOUT.SET_ON_WIDGET(row_widget, hbox)
        LAYOUT.ADD_WIDGET(outer, row_widget)
    end

    LAYOUT.SET_ON_WIDGET(container, outer)

    -- Render all tiles based on current modifier state
    local function refresh()
        for _, t in ipairs(tiles) do
            local cell = t.cell
            local style_state = {
                placeholder = cell.placeholder,
                modifier = cell.mod ~= nil,
                modifier_active = cell.mod ~= nil
                    and bit.band(state.modifiers, MOD_FOR[cell.mod]) ~= 0,
                selected = cell.key ~= nil and state.selected_key == cell.key,
            }
            if cell.key then
                style_state.binding = lookup_binding(cell.key, state.modifiers)
            end
            PROP.SET_STYLE(t.tile.widget, tile_style(style_state))
            local cmd_text = ""
            if style_state.binding then
                cmd_text = style_state.binding.label
                -- Word-wrap is on, so two lines ≈ (cell_width / 6px per char) × 2
                local max_chars = math.max(8, math.floor(cell.w * 22))
                if #cmd_text > max_chars then
                    cmd_text = cmd_text:sub(1, max_chars - 1) .. "…"
                end
            end
            PROP.SET_TEXT(t.tile.cmd_label, cmd_text)
        end
    end

    -- Wire click handlers. The Qt click filter fires for BOTH press and
    -- release; gate on "press" so each click counts once (otherwise XOR
    -- cancels itself and modifier toggles look like no-ops).
    for _, t in ipairs(tiles) do
        local cell = t.cell
        if cell.mod then
            qt_set_widget_click_handler(t.tile.widget, register_handler(function(event_type)
                if event_type ~= "press" then return end
                state.modifiers = bit.bxor(state.modifiers, MOD_FOR[cell.mod])
                refresh()
            end))
        elseif cell.key then
            qt_set_widget_click_handler(t.tile.widget, register_handler(function(event_type)
                if event_type ~= "press" then return end
                -- Toggle selection: clicking the same tile clears it
                if state.selected_key == cell.key then
                    state.selected_key = nil
                else
                    state.selected_key = cell.key
                end
                refresh()
                if opts.on_key_click then
                    opts.on_key_click(cell.key, state.modifiers, state.selected_key ~= nil)
                end
            end))
        end
        -- placeholder cells (Caps): no click handler
    end

    refresh()

    -- Called by the dialog's physical-key watcher for every KeyPress/KeyRelease.
    -- Updates modifier state unconditionally, and on a non-modifier press
    -- highlights the matching tile + notifies the click callback (so the
    -- command table filter updates the same as a mouse click would).
    local MODIFIER_KEYS = {
        [0x01000020] = true,  -- Qt::Key_Shift
        [0x01000021] = true,  -- Qt::Key_Control
        [0x01000023] = true,  -- Qt::Key_Alt
        [0x01000022] = true,  -- Qt::Key_Meta
    }
    local function handle_physical_key(event_type, key, modifiers)
        state.modifiers = modifiers
        -- Physical press SETS selection (not toggle) — pressing "a" means
        -- "highlight a", not "un-highlight a if it was already highlighted".
        -- Toggle semantics are click-only, where they're user-initiated and
        -- don't fight auto-repeat. C++ already filters autorepeat before we
        -- get here, so this fires once per physical press.
        if event_type == "press" and not MODIFIER_KEYS[key] then
            if state.selected_key ~= key then
                state.selected_key = key
                if opts.on_key_click then
                    opts.on_key_click(key, modifiers, true)
                end
            end
        end
        refresh()
    end

    return {
        widget = container,
        refresh = refresh,
        get_modifiers = function() return state.modifiers end,
        set_modifiers = function(m) state.modifiers = m; refresh() end,
        handle_physical_key = handle_physical_key,
    }
end

return M
