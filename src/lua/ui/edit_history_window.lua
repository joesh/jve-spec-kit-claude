local M = {}

local qt_constants = require("core.qt_constants")
local logger = require("core.logger")
local command_labels = require("core.command_labels")

local window_state = {
    window = nil,
    tree = nil,
    item_ids_by_sequence = {},
    listener_token = nil,
    updating_selection = false,
    command_manager = nil,
}

local function create_window()
    local window = qt_constants.WIDGET.CREATE()
    qt_constants.PROPERTIES.SET_TITLE(window, "Edit History")
    qt_constants.PROPERTIES.SET_SIZE(window, 520, 640)

    local layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(layout, 6)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(layout, 10, 10, 10, 10)

    local tree = qt_constants.WIDGET.CREATE_TREE()
    qt_constants.CONTROL.SET_TREE_HEADERS(tree, {"", "#", "Action"})
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 0, 24)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 1, 60)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 2, 380)
    qt_constants.CONTROL.SET_TREE_INDENTATION(tree, 0)
    qt_constants.CONTROL.SET_TREE_EXPANDS_ON_DOUBLE_CLICK(tree, false)

    qt_constants.LAYOUT.ADD_WIDGET(layout, tree)
    qt_constants.LAYOUT.SET_ON_WIDGET(window, layout)

    return window, tree
end

local function clear_tree()
    if not window_state.tree then
        return
    end
    qt_constants.CONTROL.CLEAR_TREE(window_state.tree)
    window_state.item_ids_by_sequence = {}
end

local function format_seq(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function refresh_tree()
    if not window_state.tree or not window_state.command_manager then
        return
    end

    local command_manager = window_state.command_manager
    local ok, entries_or_err = pcall(command_manager.list_history_entries, command_manager)
    if not ok then
        logger.error("edit_history", "Failed to load history: " .. tostring(entries_or_err))
        return
    end

    local entries = entries_or_err or {}
    local current = command_manager.get_current_sequence_number and command_manager.get_current_sequence_number() or nil
    local current_number = current or 0

    clear_tree()

    for _, entry in ipairs(entries) do
        local seq = entry.sequence_number or 0
        local marker = (seq == current_number) and "▶" or ""
        local action_label = command_labels.label_for_type(entry.command_type or "")
        local item_id = qt_constants.CONTROL.ADD_TREE_ITEM(window_state.tree, {marker, format_seq(seq), action_label})
        if item_id and item_id ~= -1 then
            qt_constants.CONTROL.SET_TREE_ITEM_DATA(window_state.tree, item_id, "sequence_number", tostring(seq))
            window_state.item_ids_by_sequence[seq] = item_id
        end
    end

    local target_item = window_state.item_ids_by_sequence[current_number]
    if target_item then
        window_state.updating_selection = true
        qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(window_state.tree, target_item)
        window_state.updating_selection = false
    end
end

local function jump_to_item(item_id)
    if not window_state.tree or not window_state.command_manager then
        return
    end
    if not item_id or item_id == -1 then
        return
    end

    local seq_str = qt_constants.CONTROL.GET_TREE_ITEM_DATA(window_state.tree, item_id, "sequence_number")
    local seq = tonumber(seq_str)
    if not seq then
        return
    end

    local ok, result_or_err = pcall(window_state.command_manager.jump_to_sequence_number, window_state.command_manager, seq)
    if not ok then
        logger.error("edit_history", "Jump failed: " .. tostring(result_or_err))
        refresh_tree()
        return
    end
    if result_or_err ~= true then
        logger.error("edit_history", "Jump failed: " .. tostring(result_or_err))
    end
    refresh_tree()
end

local function install_handlers()
    if not window_state.tree then
        return
    end

    local function register_global_handler(name, callback)
        _G[name] = function(...)
            return callback(...)
        end
        return name
    end

    local double_click = register_global_handler("__edit_history_double_click", function(item_id, _)
        if window_state.updating_selection then
            return
        end
        jump_to_item(item_id)
    end)
    qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER(window_state.tree, double_click)

    local selection = register_global_handler("__edit_history_selection", function(payload)
        if window_state.updating_selection then
            return
        end
        if payload and payload.item_id then
            -- Single-click shouldn't jump; just keep selection in sync.
            return
        end
    end)
    qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER(window_state.tree, selection)
end

function M.show(command_manager, parent_window)
    assert(command_manager, "EditHistory requires a command manager")

    if not window_state.window then
        local window, tree = create_window()
        window_state.window = window
        window_state.tree = tree
        install_handlers()
    end

    window_state.command_manager = command_manager

    if parent_window and qt_constants.WIDGET.SET_PARENT then
        pcall(qt_constants.WIDGET.SET_PARENT, window_state.window, parent_window)
    end

    if window_state.listener_token and command_manager.remove_listener then
        command_manager.remove_listener(window_state.listener_token)
        window_state.listener_token = nil
    end

    if command_manager.add_listener then
        window_state.listener_token = command_manager.add_listener(function(event)
            if not event or not event.event then
                return
            end
            if event.event == "execute" or event.event == "undo" or event.event == "redo" then
                refresh_tree()
            end
        end)
    end

    refresh_tree()
    qt_constants.DISPLAY.SHOW(window_state.window)
    qt_constants.DISPLAY.RAISE(window_state.window)
    qt_constants.DISPLAY.ACTIVATE(window_state.window)
end

return M
