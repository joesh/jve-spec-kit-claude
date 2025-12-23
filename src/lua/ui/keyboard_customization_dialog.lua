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
-- Size: ~473 LOC
-- Volatility: unknown
--
-- @file keyboard_customization_dialog.lua
-- Original intent (unreviewed):
-- Keyboard Customization Dialog
-- Provides a Lua-driven UI for inspecting and editing keyboard shortcuts.
local M = {}

local qt_constants = require('core.qt_constants')
local registry = require('core.keyboard_shortcut_registry')
local keyboard_shortcuts = require('core.keyboard_shortcuts')
local bit = require('bit')

local WIDGET = qt_constants.WIDGET
local LAYOUT = qt_constants.LAYOUT
local PROP = qt_constants.PROPERTIES
local CONTROL = qt_constants.CONTROL

-- Qt helpers ---------------------------------------------------------------

local handler_seq = 0

local function register_handler(callback)
    handler_seq = handler_seq + 1
    local name = string.format("__keyboard_dialog_handler_%d", handler_seq)
    _G[name] = function(...)
        callback(...)
    end
    return name
end

local function wrap_layout(layout)
    local container = WIDGET.CREATE()
    LAYOUT.SET_ON_WIDGET(container, layout)
    return container
end

local function add_layout(parent_layout, layout)
    LAYOUT.ADD_WIDGET(parent_layout, wrap_layout(layout))
end

local function connect_button(button, callback)
    qt_set_button_click_handler(button, register_handler(callback))
end

local function connect_line_edit_changed(line_edit, callback)
    qt_set_line_edit_text_changed_handler(line_edit, register_handler(callback))
end

local function connect_focus(widget, callback)
    qt_set_focus_handler(widget, register_handler(callback))
end

-- Module state -------------------------------------------------------------

local dialog_widget
local command_tree
local shortcuts_list
local search_box
local preset_combo
local apply_button
local status_label
local key_capture_edit

local current_command_id = nil
local pending_shortcut = nil
local capture_active = false
local has_unsaved_changes = false
local active_filter = ""
local capture_modifiers = 0

local original_global_key_handler = nil
local capture_hook_installed = false

-- Utility functions --------------------------------------------------------

local function set_status(message, is_error)
    if not status_label then
        return
    end
    local style = is_error and "color: #ff6b6b;" or "color: #aaaaaa;"
    PROP.SET_STYLE(status_label, "QLabel { " .. style .. " font-size: 11px; }")
    PROP.SET_TEXT(status_label, message or "")
end

local function set_unsaved(value)
    has_unsaved_changes = value and true or false
    if apply_button then
        PROP.SET_ENABLED(apply_button, has_unsaved_changes)
    end
end

local function build_shortcut_string(key, modifiers)
    return registry.format_shortcut(key, modifiers)
end

local function is_modifier_key(key)
    local KEY = keyboard_shortcuts.KEY
    return key == KEY.Shift or key == KEY.Control or key == KEY.Alt or key == KEY.Meta
end

local function modifier_flag_for_key(key)
    local MOD = keyboard_shortcuts.MOD
    local KEY = keyboard_shortcuts.KEY
    if key == KEY.Shift then
        return MOD.Shift
    elseif key == KEY.Control then
        return MOD.Control
    elseif key == KEY.Alt then
        return MOD.Alt
    elseif key == KEY.Meta then
        return MOD.Meta
    end
    return 0
end

local function install_global_key_capture()
    if capture_hook_installed then
        return
    end

    original_global_key_handler = _G.global_key_handler
    _G.global_key_handler = function(event)
        if capture_active then
            if not event or not event.key then
                return true
            end
            if is_modifier_key(event.key) then
                local flag = modifier_flag_for_key(event.key)
                if flag ~= 0 then
                    capture_modifiers = bit.bor(event.modifiers or 0, flag)
                else
                    capture_modifiers = event.modifiers or capture_modifiers
                end
                return true
            end

            local effective_modifiers = event.modifiers or 0
            if effective_modifiers == 0 and capture_modifiers ~= 0 then
                effective_modifiers = capture_modifiers
            end

            local shortcut_string = build_shortcut_string(event.key, effective_modifiers)
            if shortcut_string then
                pending_shortcut = shortcut_string
                PROP.SET_TEXT(key_capture_edit, shortcut_string)
                set_status("Press 'Assign Shortcut' to apply", false)
            end
            return true
        end

        if original_global_key_handler then
            return original_global_key_handler(event)
        end
        return false
    end

    capture_hook_installed = true
end

local function get_command_by_id(command_id)
    if not command_id then
        return nil
    end
    return registry.commands[command_id]
end

local function matches_filter(command, filter_text)
    if filter_text == "" then
        return true
    end
    local lower = filter_text:lower()
    if command.name and command.name:lower():find(lower, 1, true) then
        return true
    end
    if command.description and command.description:lower():find(lower, 1, true) then
        return true
    end
    if command.category and command.category:lower():find(lower, 1, true) then
        return true
    end
    for _, shortcut in ipairs(command.current_shortcuts or {}) do
        if shortcut.string:lower():find(lower, 1, true) then
            return true
        end
    end
    return false
end

-- UI population ------------------------------------------------------------

local function populate_command_tree()
    CONTROL.CLEAR_TREE(command_tree)
    local commands_by_category = registry.get_commands_by_category()

    local categories = {}
    for category in pairs(commands_by_category) do
        table.insert(categories, category)
    end
    table.sort(categories)

    for _, category in ipairs(categories) do
        local commands = commands_by_category[category]
        local added_category = false
        local category_index = nil

        for _, command in ipairs(commands) do
            if matches_filter(command, active_filter) then
                if not added_category then
                    category_index = CONTROL.ADD_TREE_ITEM(command_tree, {category, ""})
                    CONTROL.SET_TREE_ITEM_EXPANDED(command_tree, category_index, true)
                    added_category = true
                end

                local item_text = string.format("  %s", command.name)
                local child_id = CONTROL.ADD_TREE_CHILD_ITEM(command_tree, category_index, {item_text, category})
                CONTROL.SET_TREE_ITEM_DATA(command_tree, child_id, command.id)
            end
        end
    end
end

local function update_command_shortcuts_view()
    CONTROL.CLEAR_TREE(shortcuts_list)

    if not current_command_id then
        return
    end

    local command = get_command_by_id(current_command_id)
    if not command then
        return
    end

    table.sort(command.current_shortcuts, function(a, b)
        return a.string < b.string
    end)

    for _, shortcut in ipairs(command.current_shortcuts) do
        CONTROL.ADD_TREE_ITEM(shortcuts_list, {shortcut.string})
    end
end

local function populate_preset_combo()
    if not next(registry.presets) then
        registry.reset_to_defaults()
    end

    for preset_name, _ in pairs(registry.presets) do
        PROP.ADD_COMBOBOX_ITEM(preset_combo, preset_name)
    end

    if registry.current_preset then
        PROP.SET_COMBOBOX_CURRENT_TEXT(preset_combo, registry.current_preset)
    end
end

-- Event handlers -----------------------------------------------------------

local function handle_tree_selection(event)
    current_command_id = nil

    if event and event.data and event.data ~= "" then
        current_command_id = event.data
        set_status("", false)
    end

    update_command_shortcuts_view()
end

local function apply_filter(text)
    assert(type(text) == "string", "Filter text must be a string")
    active_filter = text:lower()
    populate_command_tree()
    current_command_id = nil
    update_command_shortcuts_view()
end

local function assign_pending_shortcut()
    if not current_command_id then
        set_status("Select a command before assigning a shortcut", true)
        return
    end
    if not pending_shortcut or pending_shortcut == "" then
        set_status("Press keys in the capture box before assigning", true)
        return
    end

    local success, err = registry.assign_shortcut(current_command_id, pending_shortcut)
    if not success then
        set_status(err or "Failed to assign shortcut", true)
        return
    end

    pending_shortcut = nil
    PROP.SET_TEXT(key_capture_edit, "")
    set_status("Shortcut assigned", false)
    set_unsaved(true)
    update_command_shortcuts_view()
end

local function remove_selected_shortcut()
    if not current_command_id then
        return
    end

    local command = get_command_by_id(current_command_id)
    if not command then
        return
    end

    local idx = CONTROL.GET_TREE_SELECTED_INDEX(shortcuts_list)
    if not idx or idx < 0 then
        return
    end

    local shortcut = command.current_shortcuts[idx + 1]
    if not shortcut then
        return
    end

    registry.remove_shortcut(current_command_id, shortcut.string)
    set_unsaved(true)
    update_command_shortcuts_view()
    set_status("Shortcut removed", false)
end

local function clear_all_shortcuts()
    if not current_command_id then
        return
    end

    local command = get_command_by_id(current_command_id)
    if not command then
        return
    end

    for i = #command.current_shortcuts, 1, -1 do
        local shortcut = command.current_shortcuts[i]
        registry.remove_shortcut(current_command_id, shortcut.string)
    end

    set_unsaved(true)
    update_command_shortcuts_view()
    set_status("Cleared shortcuts for command", false)
end

local function apply_changes()
    local preset_name = registry.current_preset or "Custom"
    registry.save_preset(preset_name)
    set_unsaved(false)
    set_status(string.format("Preset '%s' saved", preset_name), false)
end

local function reset_to_defaults()
    registry.reset_to_defaults()
    populate_command_tree()
    current_command_id = nil
    update_command_shortcuts_view()
    set_unsaved(true)
    set_status("Shortcuts reset to defaults", false)
end

local function handle_capture_focus(event)
    capture_active = event and event.focus_in
    if not capture_active then
        pending_shortcut = nil
        PROP.SET_TEXT(key_capture_edit, "")
        capture_modifiers = 0
    end
end

local function load_preset(name)
    local success, err = registry.load_preset(name)
    if not success then
        set_status(err or ("Failed to load preset: " .. tostring(name)), true)
        return
    end

    registry.current_preset = name
    if preset_combo then
        PROP.SET_COMBOBOX_CURRENT_TEXT(preset_combo, name)
    end
    populate_command_tree()
    current_command_id = nil
    update_command_shortcuts_view()
    pending_shortcut = nil
    if key_capture_edit then
        PROP.SET_TEXT(key_capture_edit, "")
    end
    set_unsaved(false)
    set_status(string.format("Preset '%s' loaded", name), false)
end

local function save_preset_as(name)
    if not name or name == "" then
        set_status("Enter a preset name", true)
        return
    end

    registry.save_preset(name)
    registry.current_preset = name
    PROP.ADD_COMBOBOX_ITEM(preset_combo, name)
    PROP.SET_COMBOBOX_CURRENT_TEXT(preset_combo, name)
    set_unsaved(false)
    set_status(string.format("Preset saved as '%s'", name), false)
end

-- Preset save prompt -------------------------------------------------------

local function show_save_preset_prompt()
    local prompt = WIDGET.CREATE_MAIN_WINDOW()
    PROP.SET_TITLE(prompt, "Save Keyboard Preset")
    PROP.SET_SIZE(prompt, 320, 140)

    local layout = LAYOUT.CREATE_VBOX()
    LAYOUT.ADD_WIDGET(layout, WIDGET.CREATE_LABEL("Preset name:"))

    local name_edit = WIDGET.CREATE_LINE_EDIT()
    LAYOUT.ADD_WIDGET(layout, name_edit)

    local buttons = LAYOUT.CREATE_HBOX()

    local ok_btn = WIDGET.CREATE_BUTTON("Save")
    connect_button(ok_btn, function()
        assert(PROP.GET_TEXT ~= nil, "PROP.GET_TEXT not available for preset save")
        local name = PROP.GET_TEXT(name_edit)
        assert(type(name) == "string", "PROP.GET_TEXT returned unexpected type")
        save_preset_as(name)
        qt_constants.DISPLAY.SET_VISIBLE(prompt, false)
    end)
    LAYOUT.ADD_WIDGET(buttons, ok_btn)

    local cancel_btn = WIDGET.CREATE_BUTTON("Cancel")
    connect_button(cancel_btn, function()
        qt_constants.DISPLAY.SET_VISIBLE(prompt, false)
    end)
    LAYOUT.ADD_WIDGET(buttons, cancel_btn)
    LAYOUT.ADD_STRETCH(buttons, 1)

    add_layout(layout, buttons)
    LAYOUT.SET_ON_WIDGET(prompt, layout)
    qt_constants.DISPLAY.SHOW(prompt)
    qt_constants.DISPLAY.RAISE(prompt)
    qt_constants.DISPLAY.ACTIVATE(prompt)
    qt_set_focus(name_edit)
end

-- Dialog construction ------------------------------------------------------

local function create_dialog()
    dialog_widget = WIDGET.CREATE_MAIN_WINDOW()
    PROP.SET_TITLE(dialog_widget, "Keyboard Shortcuts")
    PROP.SET_SIZE(dialog_widget, 900, 600)

    local main_layout = LAYOUT.CREATE_VBOX()

    -- Toolbar
    local toolbar = LAYOUT.CREATE_HBOX()

    local preset_label = WIDGET.CREATE_LABEL("Preset:")
    LAYOUT.ADD_WIDGET(toolbar, preset_label)

    preset_combo = WIDGET.CREATE_COMBOBOX()
    LAYOUT.ADD_WIDGET(toolbar, preset_combo)

    local load_btn = WIDGET.CREATE_BUTTON("Load")
    connect_button(load_btn, function()
        assert(PROP.GET_COMBOBOX_CURRENT_TEXT ~= nil, "PROP.GET_COMBOBOX_CURRENT_TEXT not available")
        local name = PROP.GET_COMBOBOX_CURRENT_TEXT(preset_combo)
        assert(type(name) == "string", "PROP.GET_COMBOBOX_CURRENT_TEXT returned unexpected type")
        if name ~= "" then
            load_preset(name)
        end
    end)
    LAYOUT.ADD_WIDGET(toolbar, load_btn)

    local save_btn = WIDGET.CREATE_BUTTON("Save As…")
    connect_button(save_btn, show_save_preset_prompt)
    LAYOUT.ADD_WIDGET(toolbar, save_btn)

    local reset_btn = WIDGET.CREATE_BUTTON("Reset to Defaults")
    connect_button(reset_btn, reset_to_defaults)
    LAYOUT.ADD_WIDGET(toolbar, reset_btn)

    LAYOUT.ADD_STRETCH(toolbar, 1)
    add_layout(main_layout, toolbar)

    -- Search
    search_box = WIDGET.CREATE_LINE_EDIT()
    PROP.SET_PLACEHOLDER_TEXT(search_box, "Search commands…")
    connect_line_edit_changed(search_box, function()
        assert(PROP.GET_TEXT ~= nil, "PROP.GET_TEXT not available for search filter")
        local text = PROP.GET_TEXT(search_box)
        assert(type(text) == "string", "PROP.GET_TEXT returned unexpected type")
        apply_filter(text)
    end)
    LAYOUT.ADD_WIDGET(main_layout, search_box)

    -- Main splitter
    local splitter = LAYOUT.CREATE_SPLITTER("horizontal")

    -- Command tree
    command_tree = WIDGET.CREATE_TREE()
    CONTROL.SET_TREE_HEADERS(command_tree, {"Command", "Category"})
    CONTROL.SET_TREE_COLUMN_WIDTH(command_tree, 0, 320)
    if CONTROL.SET_TREE_SELECTION_HANDLER then
        CONTROL.SET_TREE_SELECTION_HANDLER(command_tree, register_handler(handle_tree_selection))
    end
    qt_set_focus_policy(command_tree, "StrongFocus")

    -- Shortcuts panel
    local right_panel = WIDGET.CREATE()
    local right_layout = LAYOUT.CREATE_VBOX()

    local assigned_label = WIDGET.CREATE_LABEL("Assigned Shortcuts")
    PROP.SET_STYLE(assigned_label, "QLabel { font-weight: bold; }")
    LAYOUT.ADD_WIDGET(right_layout, assigned_label)

    shortcuts_list = WIDGET.CREATE_TREE()
    CONTROL.SET_TREE_HEADERS(shortcuts_list, {"Shortcut"})
    PROP.SET_MAX_HEIGHT(shortcuts_list, 140)
    LAYOUT.ADD_WIDGET(right_layout, shortcuts_list)

    local list_buttons = LAYOUT.CREATE_HBOX()
    local remove_btn = WIDGET.CREATE_BUTTON("Remove")
    connect_button(remove_btn, remove_selected_shortcut)
    LAYOUT.ADD_WIDGET(list_buttons, remove_btn)

    local clear_btn = WIDGET.CREATE_BUTTON("Clear All")
    connect_button(clear_btn, clear_all_shortcuts)
    LAYOUT.ADD_WIDGET(list_buttons, clear_btn)
    LAYOUT.ADD_STRETCH(list_buttons, 1)
    add_layout(right_layout, list_buttons)

    local capture_label = WIDGET.CREATE_LABEL("Capture Shortcut")
    PROP.SET_STYLE(capture_label, "QLabel { font-weight: bold; margin-top: 12px; }")
    LAYOUT.ADD_WIDGET(right_layout, capture_label)

    key_capture_edit = WIDGET.CREATE_LINE_EDIT()
    PROP.SET_PLACEHOLDER_TEXT(key_capture_edit, "Click and press keys…")
    qt_set_focus_policy(key_capture_edit, "StrongFocus")
    connect_focus(key_capture_edit, handle_capture_focus)
    LAYOUT.ADD_WIDGET(right_layout, key_capture_edit)

    local assign_btn = WIDGET.CREATE_BUTTON("Assign Shortcut")
    connect_button(assign_btn, assign_pending_shortcut)
    LAYOUT.ADD_WIDGET(right_layout, assign_btn)

    status_label = WIDGET.CREATE_LABEL("")
    LAYOUT.ADD_WIDGET(right_layout, status_label)
    LAYOUT.ADD_STRETCH(right_layout, 1)

    LAYOUT.SET_ON_WIDGET(right_panel, right_layout)

    LAYOUT.ADD_WIDGET(splitter, command_tree)
    LAYOUT.ADD_WIDGET(splitter, right_panel)
    LAYOUT.ADD_WIDGET(main_layout, splitter)

    -- Bottom buttons
    local bottom_bar = LAYOUT.CREATE_HBOX()
    LAYOUT.ADD_STRETCH(bottom_bar, 1)

    apply_button = WIDGET.CREATE_BUTTON("Apply")
    connect_button(apply_button, apply_changes)
    LAYOUT.ADD_WIDGET(bottom_bar, apply_button)

    local close_btn = WIDGET.CREATE_BUTTON("Close")
    connect_button(close_btn, function()
        qt_constants.DISPLAY.SET_VISIBLE(dialog_widget, false)
    end)
    LAYOUT.ADD_WIDGET(bottom_bar, close_btn)

    add_layout(main_layout, bottom_bar)

    local central_widget = WIDGET.CREATE()
    LAYOUT.SET_ON_WIDGET(central_widget, main_layout)
    if qt_constants.LAYOUT.SET_CENTRAL_WIDGET then
        qt_constants.LAYOUT.SET_CENTRAL_WIDGET(dialog_widget, central_widget)
    else
        error("qt_constants.LAYOUT.SET_CENTRAL_WIDGET not available for keyboard dialog")
    end

    populate_preset_combo()
    populate_command_tree()
    install_global_key_capture()
end

-- Public API ---------------------------------------------------------------

function M.show()
    if not dialog_widget then
        create_dialog()
    end

    qt_constants.DISPLAY.SHOW(dialog_widget)
    qt_constants.DISPLAY.RAISE(dialog_widget)
    qt_constants.DISPLAY.ACTIVATE(dialog_widget)
end

return M
