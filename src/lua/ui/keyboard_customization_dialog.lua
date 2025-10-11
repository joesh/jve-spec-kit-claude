-- Keyboard Customization Dialog (Pure Lua)
-- Premiere-style keyboard shortcut editor using Qt bindings
-- No C++ required - fully customizable by users

local M = {}

local qt = require('qt_bindings')
local registry = require('core.keyboard_shortcut_registry')

-- Dialog state
local dialog_widget = nil
local command_tree = nil
local shortcuts_list = nil
local search_box = nil
local preset_combo = nil
local current_command_id = nil
local has_unsaved_changes = false

-- Create the dialog
function M.create()
    -- Main dialog window
    dialog_widget = qt.CREATE_MAIN_WINDOW()
    qt.SET_WINDOW_TITLE(dialog_widget, "Keyboard Shortcuts")
    qt.SET_SIZE(dialog_widget, 900, 600)

    -- Main vertical layout
    local main_layout = qt.CREATE_VBOX()

    -- Top toolbar: Preset selector + buttons
    local toolbar_layout = qt.CREATE_HBOX()

    local preset_label = qt.CREATE_LABEL()
    qt.SET_TEXT(preset_label, "Preset:")
    qt.ADD_WIDGET(toolbar_layout, preset_label)

    preset_combo = qt.CREATE_COMBOBOX()
    qt.SET_MINIMUM_WIDTH(preset_combo, 200)
    qt.ADD_ITEMS(preset_combo, {"Default", "Premiere Pro", "Final Cut Pro"})
    qt.SET_COMBO_CHANGED_HANDLER(preset_combo, function(text)
        M.on_preset_changed(text)
    end)
    qt.ADD_WIDGET(toolbar_layout, preset_combo)

    local save_preset_btn = qt.CREATE_BUTTON()
    qt.SET_TEXT(save_preset_btn, "Save As...")
    qt.SET_BUTTON_CLICKED_HANDLER(save_preset_btn, M.on_save_preset_clicked)
    qt.ADD_WIDGET(toolbar_layout, save_preset_btn)

    local reset_btn = qt.CREATE_BUTTON()
    qt.SET_TEXT(reset_btn, "Reset to Defaults")
    qt.SET_BUTTON_CLICKED_HANDLER(reset_btn, M.on_reset_to_defaults_clicked)
    qt.ADD_WIDGET(toolbar_layout, reset_btn)

    qt.ADD_STRETCH(toolbar_layout)
    qt.ADD_LAYOUT(main_layout, toolbar_layout)

    -- Search box
    search_box = qt.CREATE_LINE_EDIT()
    qt.SET_PLACEHOLDER_TEXT(search_box, "Search commands...")
    qt.SET_LINE_EDIT_TEXT_CHANGED_HANDLER(search_box, function(text)
        M.apply_filter(text)
    end)
    qt.ADD_WIDGET(main_layout, search_box)

    -- Splitter for two-pane layout
    local splitter = qt.CREATE_SPLITTER()
    qt.SET_ORIENTATION(splitter, "horizontal")

    -- Left panel: Command tree
    command_tree = qt.CREATE_TREE()
    qt.SET_TREE_HEADERS(command_tree, {"Command", "Category"})
    qt.SET_TREE_COLUMN_WIDTH(command_tree, 0, 300)
    qt.SET_TREE_SELECTION_CHANGED_HANDLER(command_tree, function(item_id)
        M.on_command_selected(item_id)
    end)
    qt.ADD_WIDGET(splitter, command_tree)

    -- Right panel: Shortcuts editor
    local shortcuts_panel = M.create_shortcuts_panel()
    qt.ADD_WIDGET(splitter, shortcuts_panel)

    qt.SET_SPLITTER_STRETCH_FACTOR(splitter, 0, 2)  -- Command tree gets more space
    qt.SET_SPLITTER_STRETCH_FACTOR(splitter, 1, 1)
    qt.ADD_WIDGET(main_layout, splitter)

    -- Bottom buttons
    local button_layout = qt.CREATE_HBOX()
    qt.ADD_STRETCH(button_layout)

    local ok_btn = qt.CREATE_BUTTON()
    qt.SET_TEXT(ok_btn, "OK")
    qt.SET_BUTTON_CLICKED_HANDLER(ok_btn, function()
        M.apply_changes()
        qt.CLOSE_WINDOW(dialog_widget)
    end)
    qt.ADD_WIDGET(button_layout, ok_btn)

    local cancel_btn = qt.CREATE_BUTTON()
    qt.SET_TEXT(cancel_btn, "Cancel")
    qt.SET_BUTTON_CLICKED_HANDLER(cancel_btn, function()
        qt.CLOSE_WINDOW(dialog_widget)
    end)
    qt.ADD_WIDGET(button_layout, cancel_btn)

    local apply_btn = qt.CREATE_BUTTON()
    qt.SET_TEXT(apply_btn, "Apply")
    qt.SET_ENABLED(apply_btn, false)
    qt.SET_BUTTON_CLICKED_HANDLER(apply_btn, function()
        M.apply_changes()
        has_unsaved_changes = false
        qt.SET_ENABLED(apply_btn, false)
    end)
    qt.ADD_WIDGET(button_layout, apply_btn)

    qt.ADD_LAYOUT(main_layout, button_layout)

    -- Set main layout
    qt.SET_LAYOUT(dialog_widget, main_layout)

    -- Load commands into tree
    M.load_commands()

    return dialog_widget
end

-- Create shortcuts editor panel
function M.create_shortcuts_panel()
    local panel_layout = qt.CREATE_VBOX()

    -- Group box for assigned shortcuts
    local assigned_group = qt.CREATE_VBOX()  -- Simulating group box

    local group_label = qt.CREATE_LABEL()
    qt.SET_TEXT(group_label, "Assigned Shortcuts:")
    qt.SET_WIDGET_STYLESHEET(group_label, "QLabel { font-weight: bold; margin-top: 8px; }")
    qt.ADD_WIDGET(assigned_group, group_label)

    -- List of current shortcuts
    shortcuts_list = qt.CREATE_TREE()
    qt.SET_TREE_HEADERS(shortcuts_list, {"Shortcut"})
    qt.SET_MAXIMUM_HEIGHT(shortcuts_list, 120)
    qt.ADD_WIDGET(assigned_group, shortcuts_list)

    -- Buttons for shortcuts list
    local list_buttons = qt.CREATE_HBOX()

    local remove_btn = qt.CREATE_BUTTON()
    qt.SET_TEXT(remove_btn, "Remove")
    qt.SET_BUTTON_CLICKED_HANDLER(remove_btn, M.on_remove_shortcut_clicked)
    qt.ADD_WIDGET(list_buttons, remove_btn)

    local clear_btn = qt.CREATE_BUTTON()
    qt.SET_TEXT(clear_btn, "Clear All")
    qt.SET_BUTTON_CLICKED_HANDLER(clear_btn, M.on_clear_shortcut_clicked)
    qt.ADD_WIDGET(list_buttons, clear_btn)

    qt.ADD_STRETCH(list_buttons)
    qt.ADD_LAYOUT(assigned_group, list_buttons)

    qt.ADD_LAYOUT(panel_layout, assigned_group)

    -- Group box for adding new shortcut
    local new_group = qt.CREATE_VBOX()

    local new_label = qt.CREATE_LABEL()
    qt.SET_TEXT(new_label, "Add New Shortcut:")
    qt.SET_WIDGET_STYLESHEET(new_label, "QLabel { font-weight: bold; margin-top: 16px; }")
    qt.ADD_WIDGET(new_group, new_label)

    local help_label = qt.CREATE_LABEL()
    qt.SET_TEXT(help_label, "Press the desired key combination")
    qt.SET_WIDGET_STYLESHEET(help_label, "QLabel { color: #666; font-size: 11px; }")
    qt.ADD_WIDGET(new_group, help_label)

    -- Key capture line edit
    local key_capture = qt.CREATE_LINE_EDIT()
    qt.SET_PLACEHOLDER_TEXT(key_capture, "Click here and press keys...")
    qt.SET_READ_ONLY(key_capture, true)  -- Display only, capture via key handler
    qt.ADD_WIDGET(new_group, key_capture)

    -- TODO: Set up key capture handler
    -- This would need a new Qt binding for key event capture

    local add_btn = qt.CREATE_BUTTON()
    qt.SET_TEXT(add_btn, "Assign Shortcut")
    qt.SET_BUTTON_CLICKED_HANDLER(add_btn, M.on_add_shortcut_clicked)
    qt.ADD_WIDGET(new_group, add_btn)

    qt.ADD_LAYOUT(panel_layout, new_group)
    qt.ADD_STRETCH(panel_layout)

    -- Create container widget for the layout
    local panel_widget = qt.CREATE_MAIN_WINDOW()  -- Using main window as container
    qt.SET_LAYOUT(panel_widget, panel_layout)

    return panel_widget
end

-- Load commands into tree
function M.load_commands()
    qt.CLEAR_TREE(command_tree)

    local commands_by_category = registry.get_commands_by_category()

    -- Sort categories
    local categories = {}
    for cat in pairs(commands_by_category) do
        table.insert(categories, cat)
    end
    table.sort(categories)

    -- Add each category and its commands
    for _, category in ipairs(categories) do
        local commands = commands_by_category[category]

        -- Create category item
        local cat_id = qt.ADD_TREE_ITEM(command_tree, nil, {category, ""})
        qt.SET_TREE_ITEM_EXPANDED(command_tree, cat_id, true)

        -- Add commands under category
        for _, command in ipairs(commands) do
            local cmd_id = qt.ADD_TREE_ITEM(command_tree, cat_id, {command.name, category})
            -- Store command ID as item data
            qt.SET_TREE_ITEM_DATA(command_tree, cmd_id, command.id)
        end
    end
end

-- Filter commands based on search text
function M.apply_filter(filter_text)
    -- TODO: Implement tree filtering
    -- Would need Qt binding for QTreeWidgetItem::setHidden()
    print(string.format("Filtering by: %s", filter_text))
end

-- Command selection changed
function M.on_command_selected(item_id)
    if not item_id then
        return
    end

    -- Get command ID from item data
    local cmd_id = qt.GET_TREE_ITEM_DATA(command_tree, item_id)

    if not cmd_id or cmd_id == "" then
        -- Category selected, not a command
        current_command_id = nil
        return
    end

    current_command_id = cmd_id
    M.update_shortcuts_list()
end

-- Update shortcuts list for current command
function M.update_shortcuts_list()
    qt.CLEAR_TREE(shortcuts_list)

    if not current_command_id then
        return
    end

    local command = registry.commands[current_command_id]
    if not command then
        return
    end

    -- Add each shortcut
    for _, shortcut in ipairs(command.current_shortcuts) do
        qt.ADD_TREE_ITEM(shortcuts_list, nil, {shortcut.string})
    end
end

-- Preset changed
function M.on_preset_changed(preset_name)
    local success, err = registry.load_preset(preset_name)
    if success then
        M.load_commands()
        print(string.format("Loaded preset: %s", preset_name))
    else
        print(string.format("ERROR: Failed to load preset: %s", err or "unknown"))
    end
end

-- Save preset clicked
function M.on_save_preset_clicked()
    -- TODO: Need Qt binding for QInputDialog
    print("Save preset - input dialog needed")
end

-- Reset to defaults clicked
function M.on_reset_to_defaults_clicked()
    -- TODO: Need Qt binding for QMessageBox
    registry.reset_to_defaults()
    M.load_commands()
    print("Reset to default shortcuts")
end

-- Add shortcut clicked
function M.on_add_shortcut_clicked()
    -- TODO: Get captured key sequence and add
    print("Add shortcut - key capture needed")
end

-- Remove shortcut clicked
function M.on_remove_shortcut_clicked()
    -- TODO: Get selected shortcut and remove
    print("Remove shortcut")
end

-- Clear all shortcuts clicked
function M.on_clear_shortcut_clicked()
    if not current_command_id then
        return
    end

    local command = registry.commands[current_command_id]
    if command then
        command.current_shortcuts = {}
        M.update_shortcuts_list()
        has_unsaved_changes = true
        print(string.format("Cleared all shortcuts for: %s", command.name))
    end
end

-- Apply changes to registry
function M.apply_changes()
    -- Changes are already in the registry
    -- This would trigger saving to database/file
    print("Applied keyboard shortcut changes")
    has_unsaved_changes = false
end

-- Show the dialog
function M.show()
    if not dialog_widget then
        M.create()
    end

    qt.SHOW_WINDOW(dialog_widget)
end

return M
