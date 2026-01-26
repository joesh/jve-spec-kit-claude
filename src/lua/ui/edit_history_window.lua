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
-- Size: ~177 LOC
-- Volatility: unknown
--
-- @file edit_history_window.lua
local M = {}

local qt_constants = require("core.qt_constants")
local logger = require("core.logger")
local command_labels = require("core.command_labels")
local db_module = require("core.database")

local GEOMETRY_KEY = "edit_history_window_geometry"

local window_state = {
    window = nil,
    content = nil,
    tree = nil,
    item_ids_by_sequence = {},
    entry_by_item_id = {},
    listener_token = nil,
    updating_selection = false,
    command_manager = nil,
    geometry_ready = false,  -- Prevent saving during initial layout
}

local function save_window_geometry()
    if not window_state.window or not window_state.geometry_ready then
        return
    end
    local project_id = db_module.get_current_project_id()
    if not project_id then
        return
    end
    local x, y, w, h = qt_constants.PROPERTIES.GET_GEOMETRY(window_state.window)
    if w < 100 or h < 100 then
        return
    end
    db_module.set_project_setting(project_id, GEOMETRY_KEY, {
        x = x, y = y, width = w, height = h
    })
end

local function create_window()
    local window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
    qt_constants.PROPERTIES.SET_TITLE(window, "Edit History")

    -- Restore saved geometry or use defaults
    local project_id = db_module.get_current_project_id()
    local saved_geo = project_id and db_module.get_project_setting(project_id, GEOMETRY_KEY)
    if saved_geo and saved_geo.width and saved_geo.width > 100 and saved_geo.height and saved_geo.height > 100 then
        qt_constants.PROPERTIES.SET_GEOMETRY(window, saved_geo.x, saved_geo.y, saved_geo.width, saved_geo.height)
    else
        qt_constants.PROPERTIES.SET_SIZE(window, 520, 640)
    end

    local content = qt_constants.WIDGET.CREATE()
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
    qt_constants.LAYOUT.SET_ON_WIDGET(content, layout)
    qt_constants.LAYOUT.SET_CENTRAL_WIDGET(window, content)

    -- Install geometry change handler to persist position
    _G["__edit_history_save_geometry"] = save_window_geometry
    if qt_constants.SIGNAL and qt_constants.SIGNAL.SET_GEOMETRY_CHANGE_HANDLER then
        qt_constants.SIGNAL.SET_GEOMETRY_CHANGE_HANDLER(window, "__edit_history_save_geometry")
    end

    return window, content, tree
end

local function clear_tree()
    if not window_state.tree then
        return
    end
    qt_constants.CONTROL.CLEAR_TREE(window_state.tree)
    window_state.item_ids_by_sequence = {}
    window_state.entry_by_item_id = {}
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
        local action_label = entry.label or command_labels.label_for_type(entry.command_type or "")
        local item_id = qt_constants.CONTROL.ADD_TREE_ITEM(window_state.tree, {marker, format_seq(seq), action_label})
        if item_id and item_id ~= -1 then
            qt_constants.CONTROL.SET_TREE_ITEM_DATA(window_state.tree, item_id, "sequence_number", tostring(seq))
            window_state.item_ids_by_sequence[seq] = item_id
            window_state.entry_by_item_id[item_id] = entry
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

    local entry = window_state.entry_by_item_id[item_id]
    local seq = entry and entry.sequence_number or nil
    if not seq then
        return
    end

    local ok, success, err = pcall(window_state.command_manager.jump_to_sequence_number, window_state.command_manager, seq)
    if not ok then
        logger.error("edit_history", "Jump failed: " .. tostring(success))
        refresh_tree()
        return
    end
    if not success then
        logger.error("edit_history", "Jump failed: " .. tostring(err or "unknown"))
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

    if qt_constants.CONTROL.SET_TREE_KEY_HANDLER then
        local qt_key_escape = 0x01000000
        local key = register_global_handler("__edit_history_key", function(key_code, _text)
            if key_code ~= qt_key_escape then
                return false
            end
            if window_state.window and qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
                qt_constants.DISPLAY.SET_VISIBLE(window_state.window, false)
                return true
            end
            return true
        end)
        qt_constants.CONTROL.SET_TREE_KEY_HANDLER(window_state.tree, key)
    end
end

function M.show(command_manager, parent_window)
    assert(command_manager, "EditHistory requires a command manager")

    if not window_state.window then
        local window, content, tree = create_window()
        window_state.window = window
        window_state.content = content
        window_state.tree = tree
        install_handlers()
    end

    window_state.command_manager = command_manager

    if qt_constants.WIDGET and qt_constants.WIDGET.SET_PARENT then
        qt_constants.WIDGET.SET_PARENT(window_state.window, nil)
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

    -- Enable geometry persistence after layout settles
    qt_create_single_shot_timer(50, function()
        window_state.geometry_ready = true
    end)
end

return M
