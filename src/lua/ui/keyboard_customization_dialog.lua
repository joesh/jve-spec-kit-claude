--- Keyboard Customization Dialog (Premiere-style)
--
-- Responsibilities:
-- - Browse all registered commands by category, with search filter
-- - Show current shortcut(s) for the selected command, including @context scope
-- - Capture a new shortcut via QKeySequenceEdit (Qt-native, not a global key hook)
-- - Assign / remove / overwrite-with-confirmation
-- - Manage disk-backed presets (Save As, Load, Delete, set active for next launch)
-- - Trigger live QShortcut rewiring on every mutation (registry.rebuild_qt_shortcuts)
--
-- Non-goals (Phase 2):
-- - Visual keyboard picture (Phase 3)
-- - Modifier-tile re-coloring (Phase 3)
-- - Multi-stroke chord sequences (Premiere doesn't have these either)
--
-- Invariants:
-- - registry.M.keybindings is the single source of truth; the dialog reads via
--   registry.get_command_shortcuts() and writes via assign/remove (which both
--   call rebuild_qt_shortcuts).
-- - The dialog never installs a global key handler — capture is via
--   QKeySequenceEdit, which Qt routes around the QShortcut layer.
--
-- @file keyboard_customization_dialog.lua
local M = {}

local qt_constants = require('core.qt_constants')
local registry = require('core.keyboard_shortcut_registry')
local keyboard_picture = require('ui.keyboard_picture')

local WIDGET = qt_constants.WIDGET
local LAYOUT = qt_constants.LAYOUT
local PROP = qt_constants.PROPERTIES
local CONTROL = qt_constants.CONTROL

-- ---- Lua handler registration helper -------------------------------------

local handler_seq = 0
local function register_handler(callback)
    handler_seq = handler_seq + 1
    local name = string.format("__keyboard_dialog_handler_%d", handler_seq)
    _G[name] = function(...) callback(...) end
    return name
end

local function connect_button(button, callback)
    qt_set_button_click_handler(button, register_handler(callback))  -- luacheck: globals qt_set_button_click_handler
end

local function connect_line_edit_changed(line_edit, callback)
    qt_set_line_edit_text_changed_handler(line_edit, register_handler(callback))  -- luacheck: globals qt_set_line_edit_text_changed_handler
end

-- ---- Dialog state --------------------------------------------------------

local dialog_widget
local command_tree
local shortcuts_list
local search_box
local preset_combo
local status_label
local key_capture_edit
local assign_button
local conflict_label

local current_command_id = nil
local pending_key = nil           -- captured key code
local pending_modifiers = nil     -- captured modifier flags
local pending_conflict_id = nil   -- command_id this would overwrite (nil = no conflict)
local active_filter = ""
local key_filter = nil            -- {key, modifiers} when filtering by clicked tile
local picture = nil               -- keyboard_picture handle

-- C++ tree selection callback returns {item_id=N, items={...}} — there is no
-- event.data field. Maintain our own item_id → command_id map instead.
-- GET_TREE_SELECTED_INDEX is also a misnomer: it returns the item ID, not a
-- row index. Same lookup approach for the assigned-shortcuts list.
local item_id_to_command = {}
local shortcuts_item_id_to_sc = {}

-- ---- Status / UX feedback ------------------------------------------------

local function set_status(message, is_error)
    if not status_label then return end
    local color = is_error and "#ff8080" or "#a8a8a8"
    PROP.SET_STYLE(status_label,
        string.format("QLabel { color: %s; font-size: 11px; }", color))
    PROP.SET_TEXT(status_label, message or "")
end

-- ---- Command tree population ---------------------------------------------

local function command_matches_text_filter(cmd, filter)
    if filter == "" then return true end
    local needle = filter:lower()
    if cmd.name and cmd.name:lower():find(needle, 1, true) then return true end
    if cmd.description and cmd.description:lower():find(needle, 1, true) then return true end
    if cmd.category and cmd.category:lower():find(needle, 1, true) then return true end
    for _, sc in ipairs(registry.get_command_shortcuts(cmd.id)) do
        if sc.string:lower():find(needle, 1, true) then return true end
    end
    return false
end

local function command_matches_key_filter(cmd, kf)
    if not kf then return true end
    -- Match if the command has any binding on this key (any modifier combo)
    for _, sc in ipairs(registry.get_command_shortcuts(cmd.id)) do
        if sc.key == kf.key then return true end
    end
    return false
end

local function command_matches_filter(cmd, filter)
    return command_matches_text_filter(cmd, filter)
        and command_matches_key_filter(cmd, key_filter)
end

local function format_shortcut_with_context(sc)
    if not sc.contexts or #sc.contexts == 0 then
        return sc.string
    end
    local ctx_parts = {}
    for _, c in ipairs(sc.contexts) do ctx_parts[#ctx_parts + 1] = "@" .. c end
    return string.format("%s  %s", sc.string, table.concat(ctx_parts, " "))
end

local function shortcuts_summary(cmd_id)
    local shortcuts = registry.get_command_shortcuts(cmd_id)
    if #shortcuts == 0 then return "" end
    local parts = {}
    for _, sc in ipairs(shortcuts) do
        parts[#parts + 1] = format_shortcut_with_context(sc)
    end
    return table.concat(parts, ", ")
end

local function populate_command_tree()
    CONTROL.CLEAR_TREE(command_tree)
    item_id_to_command = {}
    local by_category = registry.get_commands_by_category()

    local cat_names = {}
    for cat in pairs(by_category) do cat_names[#cat_names + 1] = cat end
    table.sort(cat_names)

    for _, category in ipairs(cat_names) do
        local commands = by_category[category]
        local category_index = nil
        for _, cmd in ipairs(commands) do
            if command_matches_filter(cmd, active_filter) then
                if not category_index then
                    category_index = CONTROL.ADD_TREE_ITEM(command_tree, {category, ""})
                    CONTROL.SET_TREE_ITEM_EXPANDED(command_tree, category_index, true)
                end
                local child = CONTROL.ADD_TREE_CHILD_ITEM(command_tree, category_index,
                    { "  " .. cmd.name, shortcuts_summary(cmd.id) })
                item_id_to_command[child] = cmd.id
            end
        end
    end
end

-- ---- Right-pane: assigned-shortcuts list for selected command -----------

local function refresh_assigned_list()
    CONTROL.CLEAR_TREE(shortcuts_list)
    shortcuts_item_id_to_sc = {}
    if not current_command_id then return end
    for _, sc in ipairs(registry.get_command_shortcuts(current_command_id)) do
        local item_id = CONTROL.ADD_TREE_ITEM(shortcuts_list, { format_shortcut_with_context(sc) })
        shortcuts_item_id_to_sc[item_id] = sc
    end
end

-- ---- Capture-widget plumbing --------------------------------------------

local function clear_capture_state()
    pending_key = nil
    pending_modifiers = nil
    pending_conflict_id = nil
    PROP.SET_TEXT(conflict_label, "")
    CONTROL.SET_ENABLED(assign_button, false)
end

-- Read the current value out of the QKeySequenceEdit. If empty, clear state.
local function on_capture_changed()
    -- luacheck: globals qt_key_sequence_edit_get
    local key, mods = qt_key_sequence_edit_get(key_capture_edit)
    if not key then
        clear_capture_state()
        return
    end
    pending_key = key
    pending_modifiers = mods or 0

    -- Check for conflict so we can show "Already assigned to X" inline
    local conflict_id = registry.find_conflict(pending_key, pending_modifiers)
    if conflict_id and conflict_id ~= current_command_id then
        local cmd = registry.commands[conflict_id]
        assert(cmd, "conflict points at unregistered command: " .. tostring(conflict_id))
        pending_conflict_id = conflict_id
        PROP.SET_TEXT(conflict_label,
            string.format("⚠ Currently assigned to: %s — Assign will overwrite.", cmd.name))
        PROP.SET_STYLE(conflict_label,
            "QLabel { color: #ffb86b; font-size: 11px; }")
    else
        pending_conflict_id = nil
        PROP.SET_TEXT(conflict_label, "")
    end
    CONTROL.SET_ENABLED(assign_button, current_command_id ~= nil)
end

local function do_assign()
    if not current_command_id then
        set_status("Select a command first", true); return
    end
    if not pending_key then
        set_status("Capture a shortcut first", true); return
    end

    -- Format via registry so the string round-trips through the TOML parser
    local shortcut_string = registry.format_shortcut(pending_key, pending_modifiers)

    local ok, err = registry.assign_shortcut(current_command_id, shortcut_string,
        { force = pending_conflict_id ~= nil })
    if not ok then
        set_status(err or "Assignment failed", true); return
    end

    -- luacheck: globals qt_key_sequence_edit_clear
    qt_key_sequence_edit_clear(key_capture_edit)
    clear_capture_state()
    set_status(string.format("Assigned %s to %s", shortcut_string,
        registry.commands[current_command_id].name), false)
    refresh_assigned_list()
    populate_command_tree()  -- shortcut summary in the tree updates
    if picture then picture.refresh() end
end

local function do_remove_selected()
    if not current_command_id then return end
    -- GET_TREE_SELECTED_INDEX is a misnomer — returns the item ID, not a row index
    local item_id = CONTROL.GET_TREE_SELECTED_INDEX(shortcuts_list)
    if not item_id or item_id < 0 then
        set_status("Select a shortcut to remove", true); return
    end
    local sc = shortcuts_item_id_to_sc[item_id]
    if not sc then
        set_status("Select a shortcut to remove", true); return
    end
    registry.remove_shortcut(current_command_id, sc.string)
    set_status("Removed " .. sc.string, false)
    refresh_assigned_list()
    populate_command_tree()
end

-- ---- Selection handler ---------------------------------------------------

local function on_tree_selection(event)
    -- C++ payload: {item_id=N, items={...}} (or nil if selection cleared).
    -- Look up the command via our item_id → command_id map; category headers
    -- have no entry in the map, so they yield nil (no command selected).
    if event and event.item_id then
        current_command_id = item_id_to_command[event.item_id]
    else
        current_command_id = nil
    end
    clear_capture_state()
    -- luacheck: globals qt_key_sequence_edit_clear
    qt_key_sequence_edit_clear(key_capture_edit)
    refresh_assigned_list()
    if current_command_id then
        local cmd = registry.commands[current_command_id]
        set_status(string.format("Selected: %s — %s",
            cmd.name, cmd.description or ""), false)
    else
        set_status("", false)
    end
end

local function apply_search(text)
    active_filter = (text or ""):lower()
    populate_command_tree()
end

-- ---- Preset toolbar handlers ---------------------------------------------

local function refresh_preset_combo()
    PROP.CLEAR_COMBOBOX(preset_combo)
    for _, name in ipairs(registry.list_presets()) do
        PROP.ADD_COMBOBOX_ITEM(preset_combo, name)
    end
    -- current_preset is authoritative: the registry always has one set
    -- (either DEFAULT_PRESET or the loaded preset's name). The on-disk active
    -- pointer is its persistence; the in-memory field is what's live now.
    assert(registry.current_preset,
        "refresh_preset_combo: registry.current_preset unset")
    PROP.SET_COMBOBOX_CURRENT_TEXT(preset_combo, registry.current_preset)
end

local function do_load_preset()
    -- luacheck: globals qt_get_combobox_current_text
    local name = PROP.GET_COMBOBOX_CURRENT_TEXT(preset_combo)
    if not name or name == "" then return end
    local ok, err = registry.load_preset(name)
    if not ok then set_status(err or "Load failed", true); return end
    registry.set_active_preset(name == registry.DEFAULT_PRESET and nil or name)
    populate_command_tree()
    refresh_assigned_list()
    if picture then picture.refresh() end
    set_status(string.format("Loaded preset '%s'", name), false)
end

-- Inline "Save preset as…" prompt — child modal QDialog parented to our
-- main dialog so the application-modal stack works (a tool window would be
-- blocked by our parent's Qt::ApplicationModal).
local function show_save_as_prompt()
    local prompt = qt_constants.DIALOG.CREATE("Save Keyboard Preset", 360, 140, dialog_widget)

    local layout = LAYOUT.CREATE_VBOX()
    LAYOUT.ADD_WIDGET(layout, WIDGET.CREATE_LABEL("Preset name:"))

    local name_edit = WIDGET.CREATE_LINE_EDIT()
    LAYOUT.ADD_WIDGET(layout, name_edit)

    local row = LAYOUT.CREATE_HBOX()
    LAYOUT.ADD_STRETCH(row, 1)

    local cancel = WIDGET.CREATE_BUTTON("Cancel")
    connect_button(cancel, function() qt_constants.DIALOG.CLOSE(prompt, false) end)
    LAYOUT.ADD_WIDGET(row, cancel)

    local save = WIDGET.CREATE_BUTTON("Save")
    connect_button(save, function()
        local name = PROP.GET_TEXT(name_edit)
        if not name or name == "" then return end
        if name == registry.DEFAULT_PRESET then
            set_status("Cannot overwrite bundled Default — choose another name", true)
            return
        end
        registry.save_preset(name)
        registry.set_active_preset(name)
        refresh_preset_combo()
        qt_constants.DIALOG.CLOSE(prompt, true)
        set_status(string.format("Saved preset '%s'", name), false)
    end)
    LAYOUT.ADD_WIDGET(row, save)

    local row_widget = WIDGET.CREATE()
    LAYOUT.SET_ON_WIDGET(row_widget, row)
    LAYOUT.ADD_WIDGET(layout, row_widget)

    qt_constants.DIALOG.SET_LAYOUT(prompt, layout)
    qt_constants.DIALOG.SHOW(prompt, false)
    qt_set_focus(name_edit)  -- luacheck: globals qt_set_focus
end

local function do_delete_preset()
    local name = PROP.GET_COMBOBOX_CURRENT_TEXT(preset_combo)
    if not name or name == "" or name == registry.DEFAULT_PRESET then
        set_status("Cannot delete bundled Default", true); return
    end
    registry.delete_preset(name)
    refresh_preset_combo()
    set_status(string.format("Deleted preset '%s'", name), false)
end

local function do_reset_to_defaults()
    registry.reset_to_defaults()
    refresh_preset_combo()
    populate_command_tree()
    refresh_assigned_list()
    if picture then picture.refresh() end
    set_status("Reset to bundled defaults", false)
end

-- ---- Dialog construction -------------------------------------------------

-- Wrap an HBox inside a container widget so it can be added to the outer
-- VBox (LAYOUT.ADD_WIDGET takes widgets, not layouts).
local function hbox_as_widget(hbox)
    local w = WIDGET.CREATE()
    LAYOUT.SET_ON_WIDGET(w, hbox)
    return w
end

-- Preset row: [Preset:] [combo] [Load] [Save As…] [Delete] [Reset to Defaults]
local function build_preset_toolbar()
    local toolbar = LAYOUT.CREATE_HBOX()
    LAYOUT.ADD_WIDGET(toolbar, WIDGET.CREATE_LABEL("Preset:"))

    preset_combo = WIDGET.CREATE_COMBOBOX()
    LAYOUT.ADD_WIDGET(toolbar, preset_combo)

    for _, spec in ipairs({
        { "Load",              do_load_preset       },
        { "Save As…",          show_save_as_prompt  },
        { "Delete",            do_delete_preset     },
        { "Reset to Defaults", do_reset_to_defaults },
    }) do
        local btn = WIDGET.CREATE_BUTTON(spec[1])
        connect_button(btn, spec[2])
        LAYOUT.ADD_WIDGET(toolbar, btn)
    end

    LAYOUT.ADD_STRETCH(toolbar, 1)
    return hbox_as_widget(toolbar)
end

-- Visual keyboard (Premiere-style). Click a key tile to filter the command
-- table to bindings on that key; click a modifier tile to toggle the displayed
-- modifier overlay. Selection is owned by the picture so tile highlight and
-- filter stay in lockstep.
local function build_keyboard_picture_widget()
    picture = keyboard_picture.create({
        on_key_click = function(key, _modifiers, is_selected)
            if is_selected then
                key_filter = { key = key }
            else
                key_filter = nil
            end
            populate_command_tree()
        end,
    })
    return picture.widget
end

local function build_search_box()
    search_box = WIDGET.CREATE_LINE_EDIT()
    PROP.SET_PLACEHOLDER_TEXT(search_box, "Search commands, descriptions, shortcuts…")
    connect_line_edit_changed(search_box, function()
        apply_search(PROP.GET_TEXT(search_box))
    end)
    return search_box
end

local function build_command_tree()
    command_tree = WIDGET.CREATE_TREE()
    CONTROL.SET_TREE_HEADERS(command_tree, { "Command", "Shortcut" })
    CONTROL.SET_TREE_COLUMN_WIDTH(command_tree, 0, 320)
    CONTROL.SET_TREE_COLUMN_WIDTH(command_tree, 1, 240)
    CONTROL.SET_TREE_SELECTION_HANDLER(command_tree, register_handler(on_tree_selection))
    qt_set_focus_policy(command_tree, "StrongFocus")  -- luacheck: globals qt_set_focus_policy
    return command_tree
end

-- Right-side detail pane: assigned shortcuts list + capture editor + status.
local function build_detail_pane()
    local detail = WIDGET.CREATE()
    local vbox = LAYOUT.CREATE_VBOX()

    local assigned_label = WIDGET.CREATE_LABEL("Assigned Shortcuts")
    PROP.SET_STYLE(assigned_label, "QLabel { font-weight: bold; }")
    LAYOUT.ADD_WIDGET(vbox, assigned_label)

    shortcuts_list = WIDGET.CREATE_TREE()
    CONTROL.SET_TREE_HEADERS(shortcuts_list, { "Shortcut" })
    PROP.SET_MAX_HEIGHT(shortcuts_list, 160)
    LAYOUT.ADD_WIDGET(vbox, shortcuts_list)

    local list_buttons = LAYOUT.CREATE_HBOX()
    local remove_btn = WIDGET.CREATE_BUTTON("Remove Selected")
    connect_button(remove_btn, do_remove_selected)
    LAYOUT.ADD_WIDGET(list_buttons, remove_btn)
    LAYOUT.ADD_STRETCH(list_buttons, 1)
    LAYOUT.ADD_WIDGET(vbox, hbox_as_widget(list_buttons))

    local capture_label = WIDGET.CREATE_LABEL("Capture New Shortcut")
    PROP.SET_STYLE(capture_label, "QLabel { font-weight: bold; margin-top: 12px; }")
    LAYOUT.ADD_WIDGET(vbox, capture_label)

    -- luacheck: globals qt_create_key_sequence_edit qt_key_sequence_edit_on_changed
    key_capture_edit = qt_create_key_sequence_edit()
    qt_key_sequence_edit_on_changed(key_capture_edit, register_handler(on_capture_changed))
    LAYOUT.ADD_WIDGET(vbox, key_capture_edit)

    conflict_label = WIDGET.CREATE_LABEL("")
    LAYOUT.ADD_WIDGET(vbox, conflict_label)

    assign_button = WIDGET.CREATE_BUTTON("Assign Shortcut")
    CONTROL.SET_ENABLED(assign_button, false)
    connect_button(assign_button, do_assign)
    LAYOUT.ADD_WIDGET(vbox, assign_button)

    status_label = WIDGET.CREATE_LABEL("")
    LAYOUT.ADD_WIDGET(vbox, status_label)
    LAYOUT.ADD_STRETCH(vbox, 1)

    LAYOUT.SET_ON_WIDGET(detail, vbox)
    return detail
end

-- Command tree (left) | detail pane (right), horizontal splitter.
local function build_command_splitter()
    local splitter = LAYOUT.CREATE_SPLITTER("horizontal")
    LAYOUT.ADD_WIDGET(splitter, build_command_tree())
    LAYOUT.ADD_WIDGET(splitter, build_detail_pane())
    return splitter
end

-- Close button at the lower-right. Mutations apply immediately, so no "Apply".
local function build_bottom_bar()
    local bottom = LAYOUT.CREATE_HBOX()
    LAYOUT.ADD_STRETCH(bottom, 1)
    local close_btn = WIDGET.CREATE_BUTTON("Close")
    connect_button(close_btn, function()
        qt_constants.DIALOG.CLOSE(dialog_widget, true)
    end)
    LAYOUT.ADD_WIDGET(bottom, close_btn)
    return hbox_as_widget(bottom)
end

-- Forward physical key press/release events on the dialog to the picture so
-- the visual keyboard reflects held modifiers and the tile matching the last
-- pressed key highlights.
local function install_physical_key_watcher()
    -- luacheck: globals qt_install_key_state_watcher
    qt_install_key_state_watcher(dialog_widget, register_handler(function(event_type, key, mods)
        assert(picture, "key watcher fired before picture was constructed")
        picture.handle_physical_key(event_type, key, mods)
    end))
end

local function create_dialog()
    -- Modal QDialog (Qt::ApplicationModal) — isolates from global QShortcuts
    -- on the main window so Delete, J/K/L, etc. don't leak to the timeline.
    dialog_widget = qt_constants.DIALOG.CREATE("Keyboard Shortcuts", 1200, 880, nil)

    local main = LAYOUT.CREATE_VBOX()
    LAYOUT.ADD_WIDGET(main, build_preset_toolbar())
    LAYOUT.ADD_WIDGET(main, build_keyboard_picture_widget())
    LAYOUT.ADD_WIDGET(main, build_search_box())
    LAYOUT.ADD_WIDGET(main, build_command_splitter())
    LAYOUT.ADD_WIDGET(main, build_bottom_bar())

    qt_constants.DIALOG.SET_LAYOUT(dialog_widget, main)
    install_physical_key_watcher()

    refresh_preset_combo()
    populate_command_tree()
end

-- ---- Public API ---------------------------------------------------------

function M.show()
    if not dialog_widget then create_dialog() end
    -- Re-sync state in case bindings changed since last open
    refresh_preset_combo()
    populate_command_tree()
    refresh_assigned_list()
    if picture then picture.refresh() end
    -- DIALOG.SHOW(dialog, blocking=false) shows modally without blocking the
    -- Lua call (we want to return to the menu dispatcher promptly).
    qt_constants.DIALOG.SHOW(dialog_widget, false)
end

return M
