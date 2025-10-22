-- Keyboard Customization Dialog - Premiere Pro Visual Style
-- Complete visual redesign to match Adobe Premiere Pro's keyboard shortcuts dialog

local M = {}

local ui_constants = require("core.ui_constants")

-- Premiere Pro color scheme
local COLORS = {
    -- Backgrounds
    WINDOW_BG = "#1e1e1e",           -- Main window background
    PANEL_BG = "#252525",            -- Panel background
    HEADER_BG = "#2d2d2d",           -- Header bars
    INPUT_BG = "#323232",            -- Input fields
    SELECTED_BG = "#094771",         -- Selected item (Premiere blue)
    HOVER_BG = "#2a2a2a",            -- Hover state

    -- Borders
    BORDER_DARK = "#0f0f0f",         -- Dark borders
    BORDER_MEDIUM = "#3a3a3a",       -- Medium borders
    BORDER_LIGHT = "#4a4a4a",        -- Light borders

    -- Text
    TEXT_PRIMARY = "#e8e8e8",        -- Main text
    TEXT_SECONDARY = "#a0a0a0",      -- Secondary text
    TEXT_DISABLED = "#6a6a6a",       -- Disabled text
    TEXT_SHORTCUT = "#d4d4d4",       -- Shortcut keys (monospace)
    TEXT_CONFLICT = "#ff6b6b",       -- Conflict warning
    TEXT_HEADER = "#ffffff",         -- Headers

    -- Accents
    ACCENT_BLUE = "#0078d4",         -- Focus/accent
    ACCENT_ORANGE = "#ff8c00",       -- Warning
    BUTTON_BG = "#3a3a3a",           -- Button background
    BUTTON_HOVER = "#4a4a4a",        -- Button hover
}

-- Create the main dialog
function M.create()
    -- Main window
    local window = CREATE_MAIN_WINDOW()
    SET_WINDOW_TITLE(window, "Keyboard Shortcuts")
    SET_SIZE(window, 1000, 650)

    -- Apply dark theme to entire window
    SET_WIDGET_STYLESHEET(window, string.format([[
        QMainWindow, QDialog {
            background-color: %s;
            color: %s;
        }
        QLabel {
            color: %s;
            background: transparent;
        }
        QPushButton {
            background-color: %s;
            color: %s;
            border: 1px solid %s;
            padding: 6px 16px;
            border-radius: 2px;
            min-width: 70px;
        }
        QPushButton:hover {
            background-color: %s;
            border: 1px solid %s;
        }
        QPushButton:pressed {
            background-color: %s;
        }
        QLineEdit {
            background-color: %s;
            color: %s;
            border: 1px solid %s;
            padding: 6px;
            border-radius: 2px;
        }
        QLineEdit:focus {
            border: 1px solid %s;
        }
        QComboBox {
            background-color: %s;
            color: %s;
            border: 1px solid %s;
            padding: 4px 8px;
            border-radius: 2px;
        }
        QComboBox:hover {
            border: 1px solid %s;
        }
        QTreeWidget {
            background-color: %s;
            color: %s;
            border: 1px solid %s;
            alternate-background-color: %s;
            selection-background-color: %s;
            selection-color: %s;
            outline: none;
        }
        QTreeWidget::item {
            padding: 4px;
            border: none;
        }
        QTreeWidget::item:hover {
            background-color: %s;
        }
        QTreeWidget::item:selected {
            background-color: %s;
            color: %s;
        }
        QHeaderView::section {
            background-color: %s;
            color: %s;
            padding: 6px;
            border: none;
            border-bottom: 1px solid %s;
            border-right: 1px solid %s;
            font-weight: bold;
        }
        QScrollBar:vertical {
            background: %s;
            width: 12px;
            border: none;
        }
        QScrollBar::handle:vertical {
            background: %s;
            border-radius: 6px;
            min-height: 20px;
        }
        QScrollBar::handle:vertical:hover {
            background: %s;
        }
        QSplitter::handle {
            background: %s;
        }
    ]],
        COLORS.WINDOW_BG, COLORS.TEXT_PRIMARY,
        COLORS.TEXT_PRIMARY,
        COLORS.BUTTON_BG, COLORS.TEXT_PRIMARY, COLORS.BORDER_MEDIUM,
        COLORS.BUTTON_HOVER, COLORS.BORDER_LIGHT,
        COLORS.BORDER_DARK,
        COLORS.INPUT_BG, COLORS.TEXT_PRIMARY, COLORS.BORDER_MEDIUM,
        COLORS.ACCENT_BLUE,
        COLORS.INPUT_BG, COLORS.TEXT_PRIMARY, COLORS.BORDER_MEDIUM,
        COLORS.BORDER_LIGHT,
        COLORS.PANEL_BG, COLORS.TEXT_PRIMARY, COLORS.BORDER_DARK,
        COLORS.PANEL_BG, COLORS.SELECTED_BG, COLORS.TEXT_PRIMARY,
        COLORS.HOVER_BG,
        COLORS.SELECTED_BG, COLORS.TEXT_PRIMARY,
        COLORS.HEADER_BG, COLORS.TEXT_HEADER, COLORS.BORDER_DARK, COLORS.BORDER_DARK,
        COLORS.PANEL_BG,
        COLORS.BORDER_MEDIUM, COLORS.BORDER_LIGHT,
        COLORS.BORDER_DARK
    ))

    -- Main layout
    local main_layout = CREATE_VBOX()
    SET_LAYOUT_MARGIN(main_layout, 0)
    SET_LAYOUT_SPACING(main_layout, 0)

    -- Top toolbar section with dark header background
    local toolbar_widget = CREATE_WIDGET()
    SET_WIDGET_STYLESHEET(toolbar_widget, string.format(
        "QWidget { background-color: %s; padding: 8px; border-bottom: 1px solid %s; }",
        COLORS.HEADER_BG, COLORS.BORDER_DARK
    ))
    local toolbar_layout = CREATE_HBOX()
    SET_LAYOUT_MARGIN(toolbar_layout, 8)
    SET_LAYOUT_SPACING(toolbar_layout, 12)

    -- Preset label and dropdown
    local preset_label = CREATE_LABEL()
    SET_TEXT(preset_label, "Keyboard Layout Preset:")
    SET_WIDGET_STYLESHEET(preset_label, string.format(
        "QLabel { color: %s; font-weight: bold; }",
        COLORS.TEXT_PRIMARY
    ))
    ADD_WIDGET(toolbar_layout, preset_label)

    local preset_combo = CREATE_COMBOBOX()
    SET_MINIMUM_WIDTH(preset_combo, 200)
    ADD_COMBOBOX_ITEM(preset_combo, "Default")
    ADD_COMBOBOX_ITEM(preset_combo, "Adobe Premiere Pro")
    ADD_COMBOBOX_ITEM(preset_combo, "Final Cut Pro")
    ADD_COMBOBOX_ITEM(preset_combo, "Custom")
    ADD_WIDGET(toolbar_layout, preset_combo)

    -- Save As button
    local save_btn = CREATE_BUTTON()
    SET_TEXT(save_btn, "Save As...")
    ADD_WIDGET(toolbar_layout, save_btn)

    ADD_STRETCH(toolbar_layout)

    -- Clear All and Undo buttons
    local clear_btn = CREATE_BUTTON()
    SET_TEXT(clear_btn, "Clear")
    SET_WIDGET_STYLESHEET(clear_btn, string.format(
        "QPushButton { color: %s; }",
        COLORS.TEXT_SECONDARY
    ))
    ADD_WIDGET(toolbar_layout, clear_btn)

    local undo_btn = CREATE_BUTTON()
    SET_TEXT(undo_btn, "Undo")
    ADD_WIDGET(toolbar_layout, undo_btn)

    SET_LAYOUT(toolbar_widget, toolbar_layout)
    ADD_WIDGET(main_layout, toolbar_widget)

    -- Search bar section
    local search_widget = CREATE_WIDGET()
    SET_WIDGET_STYLESHEET(search_widget, string.format(
        "QWidget { background-color: %s; padding: 8px; border-bottom: 1px solid %s; }",
        COLORS.PANEL_BG, COLORS.BORDER_DARK
    ))
    local search_layout = CREATE_HBOX()
    SET_LAYOUT_MARGIN(search_layout, 8)
    SET_LAYOUT_SPACING(search_layout, 8)

    local search_label = CREATE_LABEL()
    SET_TEXT(search_label, "Search:")
    ADD_WIDGET(search_layout, search_label)

    local search_input = CREATE_LINE_EDIT()
    SET_PLACEHOLDER_TEXT(search_input, "Type to filter commands...")
    ADD_WIDGET(search_layout, search_input)

    SET_LAYOUT(search_widget, search_layout)
    ADD_WIDGET(main_layout, search_widget)

    -- Main content area: three-column layout
    local content_splitter = CREATE_SPLITTER()
    SET_ORIENTATION(content_splitter, "horizontal")

    -- LEFT COLUMN: Command List
    local command_panel = M.create_command_list_panel()
    ADD_WIDGET(content_splitter, command_panel)

    -- MIDDLE COLUMN: Assigned Shortcuts
    local shortcuts_panel = M.create_shortcuts_panel()
    ADD_WIDGET(content_splitter, shortcuts_panel)

    -- RIGHT COLUMN: Shortcut Details
    local details_panel = M.create_details_panel()
    ADD_WIDGET(content_splitter, details_panel)

    -- Set splitter proportions (40% / 30% / 30%)
    SET_SPLITTER_SIZES(content_splitter, {400, 300, 300})

    ADD_WIDGET(main_layout, content_splitter)

    -- Bottom button bar
    local button_bar = CREATE_WIDGET()
    SET_WIDGET_STYLESHEET(button_bar, string.format(
        "QWidget { background-color: %s; padding: 8px; border-top: 1px solid %s; }",
        COLORS.HEADER_BG, COLORS.BORDER_DARK
    ))
    local button_layout = CREATE_HBOX()
    SET_LAYOUT_MARGIN(button_layout, 8)
    SET_LAYOUT_SPACING(button_layout, 8)

    ADD_STRETCH(button_layout)

    local ok_btn = CREATE_BUTTON()
    SET_TEXT(ok_btn, "OK")
    SET_WIDGET_STYLESHEET(ok_btn, string.format(
        "QPushButton { background-color: %s; font-weight: bold; min-width: 90px; }",
        COLORS.ACCENT_BLUE
    ))
    ADD_WIDGET(button_layout, ok_btn)

    local cancel_btn = CREATE_BUTTON()
    SET_TEXT(cancel_btn, "Cancel")
    SET_MINIMUM_WIDTH(cancel_btn, 90)
    ADD_WIDGET(button_layout, cancel_btn)

    SET_LAYOUT(button_bar, button_layout)
    ADD_WIDGET(main_layout, button_bar)

    -- Set main layout
    SET_LAYOUT(window, main_layout)

    return window
end

-- Create left panel: Command list with categories
function M.create_command_list_panel()
    local panel = CREATE_WIDGET()
    local layout = CREATE_VBOX()
    SET_LAYOUT_MARGIN(layout, 0)
    SET_LAYOUT_SPACING(layout, 0)

    -- Header
    local header = CREATE_LABEL()
    SET_TEXT(header, "Commands")
    SET_WIDGET_STYLESHEET(header, string.format([[
        QLabel {
            background-color: %s;
            color: %s;
            padding: 8px;
            font-weight: bold;
            border-bottom: 1px solid %s;
        }
    ]], COLORS.HEADER_BG, COLORS.TEXT_HEADER, COLORS.BORDER_DARK))
    ADD_WIDGET(layout, header)

    -- Command tree
    local tree = CREATE_TREE()
    SET_TREE_HEADERS(tree, {"Command"})
    SET_TREE_COLUMN_WIDTH(tree, 0, 350)

    -- Add sample categories and commands
    local edit_cat = ADD_TREE_ITEM(tree, nil, {"Edit"})
    SET_TREE_ITEM_EXPANDED(tree, edit_cat, true)
    ADD_TREE_ITEM(tree, edit_cat, {"  Undo"})
    ADD_TREE_ITEM(tree, edit_cat, {"  Redo"})
    ADD_TREE_ITEM(tree, edit_cat, {"  Cut"})
    ADD_TREE_ITEM(tree, edit_cat, {"  Copy"})
    ADD_TREE_ITEM(tree, edit_cat, {"  Paste"})

    local playback_cat = ADD_TREE_ITEM(tree, nil, {"Playback"})
    SET_TREE_ITEM_EXPANDED(tree, playback_cat, true)
    ADD_TREE_ITEM(tree, playback_cat, {"  Play/Pause"})
    ADD_TREE_ITEM(tree, playback_cat, {"  Step Forward"})
    ADD_TREE_ITEM(tree, playback_cat, {"  Step Backward"})
    ADD_TREE_ITEM(tree, playback_cat, {"  Play In to Out"})

    local timeline_cat = ADD_TREE_ITEM(tree, nil, {"Timeline"})
    SET_TREE_ITEM_EXPANDED(tree, timeline_cat, true)
    ADD_TREE_ITEM(tree, timeline_cat, {"  Ripple Delete"})
    ADD_TREE_ITEM(tree, timeline_cat, {"  Lift"})
    ADD_TREE_ITEM(tree, timeline_cat, {"  Extract"})
    ADD_TREE_ITEM(tree, timeline_cat, {"  Insert Edit"})
    ADD_TREE_ITEM(tree, timeline_cat, {"  Overwrite Edit"})

    ADD_WIDGET(layout, tree)
    SET_LAYOUT(panel, layout)

    return panel
end

-- Create middle panel: Assigned shortcuts
function M.create_shortcuts_panel()
    local panel = CREATE_WIDGET()
    local layout = CREATE_VBOX()
    SET_LAYOUT_MARGIN(layout, 0)
    SET_LAYOUT_SPACING(layout, 8)

    -- Header
    local header = CREATE_LABEL()
    SET_TEXT(header, "Shortcuts")
    SET_WIDGET_STYLESHEET(header, string.format([[
        QLabel {
            background-color: %s;
            color: %s;
            padding: 8px;
            font-weight: bold;
            border-bottom: 1px solid %s;
        }
    ]], COLORS.HEADER_BG, COLORS.TEXT_HEADER, COLORS.BORDER_DARK))
    ADD_WIDGET(layout, header)

    -- Content area with padding
    local content_widget = CREATE_WIDGET()
    local content_layout = CREATE_VBOX()
    SET_LAYOUT_MARGIN(content_layout, 12)
    SET_LAYOUT_SPACING(content_layout, 8)

    -- Shortcuts list
    local shortcuts_list = CREATE_TREE()
    SET_TREE_HEADERS(shortcuts_list, {"Shortcut"})
    SET_MAXIMUM_HEIGHT(shortcuts_list, 150)

    -- Example shortcuts with monospace font
    local item1 = ADD_TREE_ITEM(shortcuts_list, nil, {"Cmd+Z"})
    local item2 = ADD_TREE_ITEM(shortcuts_list, nil, {"Ctrl+Z"})

    ADD_WIDGET(content_layout, shortcuts_list)

    -- Buttons
    local btn_layout = CREATE_HBOX()
    SET_LAYOUT_SPACING(btn_layout, 8)

    local add_btn = CREATE_BUTTON()
    SET_TEXT(add_btn, "Add")
    ADD_WIDGET(btn_layout, add_btn)

    local remove_btn = CREATE_BUTTON()
    SET_TEXT(remove_btn, "Remove")
    ADD_WIDGET(btn_layout, remove_btn)

    ADD_STRETCH(btn_layout)
    ADD_LAYOUT(content_layout, btn_layout)

    -- Separator
    local separator = CREATE_LABEL()
    SET_TEXT(separator, "")
    SET_WIDGET_STYLESHEET(separator, string.format(
        "QLabel { border-top: 1px solid %s; margin: 8px 0; }",
        COLORS.BORDER_MEDIUM
    ))
    ADD_WIDGET(content_layout, separator)

    -- New shortcut section
    local new_label = CREATE_LABEL()
    SET_TEXT(new_label, "Set New Shortcut:")
    SET_WIDGET_STYLESHEET(new_label, string.format(
        "QLabel { color: %s; font-weight: bold; }",
        COLORS.TEXT_PRIMARY
    ))
    ADD_WIDGET(content_layout, new_label)

    local key_input = CREATE_LINE_EDIT()
    SET_PLACEHOLDER_TEXT(key_input, "Click and press keys...")
    SET_READ_ONLY(key_input, true)
    ADD_WIDGET(content_layout, key_input)

    local assign_btn = CREATE_BUTTON()
    SET_TEXT(assign_btn, "Assign")
    SET_WIDGET_STYLESHEET(assign_btn, string.format(
        "QPushButton { background-color: %s; font-weight: bold; }",
        COLORS.ACCENT_BLUE
    ))
    ADD_WIDGET(content_layout, assign_btn)

    ADD_STRETCH(content_layout)

    SET_LAYOUT(content_widget, content_layout)
    ADD_WIDGET(layout, content_widget)

    SET_LAYOUT(panel, layout)
    return panel
end

-- Create right panel: Shortcut details and modifiers
function M.create_details_panel()
    local panel = CREATE_WIDGET()
    local layout = CREATE_VBOX()
    SET_LAYOUT_MARGIN(layout, 0)
    SET_LAYOUT_SPACING(layout, 0)

    -- Header
    local header = CREATE_LABEL()
    SET_TEXT(header, "Modifiers")
    SET_WIDGET_STYLESHEET(header, string.format([[
        QLabel {
            background-color: %s;
            color: %s;
            padding: 8px;
            font-weight: bold;
            border-bottom: 1px solid %s;
        }
    ]], COLORS.HEADER_BG, COLORS.TEXT_HEADER, COLORS.BORDER_DARK))
    ADD_WIDGET(layout, header)

    -- Content with padding
    local content_widget = CREATE_WIDGET()
    local content_layout = CREATE_VBOX()
    SET_LAYOUT_MARGIN(content_layout, 12)
    SET_LAYOUT_SPACING(content_layout, 12)

    -- Modifier checkboxes
    local ctrl_cb = CREATE_CHECKBOX()
    SET_TEXT(ctrl_cb, "Ctrl")
    ADD_WIDGET(content_layout, ctrl_cb)

    local shift_cb = CREATE_CHECKBOX()
    SET_TEXT(shift_cb, "Shift")
    ADD_WIDGET(content_layout, shift_cb)

    local alt_cb = CREATE_CHECKBOX()
    SET_TEXT(alt_cb, "Alt")
    ADD_WIDGET(content_layout, alt_cb)

    local cmd_cb = CREATE_CHECKBOX()
    SET_TEXT(cmd_cb, "Cmd/Meta")
    ADD_WIDGET(content_layout, cmd_cb)

    -- Separator
    local separator = CREATE_LABEL()
    SET_TEXT(separator, "")
    SET_WIDGET_STYLESHEET(separator, string.format(
        "QLabel { border-top: 1px solid %s; margin: 8px 0; }",
        COLORS.BORDER_MEDIUM
    ))
    ADD_WIDGET(content_layout, separator)

    -- Conflict warning
    local conflict_label = CREATE_LABEL()
    SET_TEXT(conflict_label, "⚠ Conflict with:")
    SET_WIDGET_STYLESHEET(conflict_label, string.format(
        "QLabel { color: %s; font-weight: bold; }",
        COLORS.TEXT_CONFLICT
    ))
    ADD_WIDGET(content_layout, conflict_label)

    local conflict_text = CREATE_LABEL()
    SET_TEXT(conflict_text, "Edit > Copy\nEdit > Paste")
    SET_WIDGET_STYLESHEET(conflict_text, string.format(
        "QLabel { color: %s; padding: 8px; background-color: %s; border: 1px solid %s; border-radius: 2px; }",
        COLORS.TEXT_CONFLICT, COLORS.PANEL_BG, COLORS.ACCENT_ORANGE
    ))
    ADD_WIDGET(content_layout, conflict_text)

    -- Info text
    local info_label = CREATE_LABEL()
    SET_TEXT(info_label, "This shortcut is already assigned to another command. Assigning it will remove the previous assignment.")
    SET_WIDGET_STYLESHEET(info_label, string.format(
        "QLabel { color: %s; font-size: 11px; padding: 8px; }",
        COLORS.TEXT_SECONDARY
    ))
    SET_WORD_WRAP(info_label, true)
    ADD_WIDGET(content_layout, info_label)

    ADD_STRETCH(content_layout)

    SET_LAYOUT(content_widget, content_layout)
    ADD_WIDGET(layout, content_widget)

    SET_LAYOUT(panel, layout)
    return panel
end

-- Show the dialog
function M.show()
    local window = M.create()
    SHOW_WINDOW(window)
    return window
end

return M
