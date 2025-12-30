-- @file project_browser.lua
-- Project Browser panel controller

local qt_constants     = require("qt_constants")
local ui_constants     = require("ui_constants")
local command_manager  = require("command_manager")
local command_scope    = require("command_scope")
local tag_service      = require("tag_service")
local logger           = require("logger")
local dkjson           = require("dkjson")
local uuid             = require("uuid")

local browser_state    = require("ui.project_browser.browser_state")
local browser_tree     = require("ui.project_browser.browser_tree")
local browser_actions  = require("ui.project_browser.browser_actions")
local keymap           = require("ui.project_browser.keymap")

local M = {}

local ACTIVATE_COMMAND = "project_browser.activate"

local tree_context
local tab_container
local tab_label
local layout

local is_restoring_selection = false

-- ============================================================================
-- Panel lifecycle & orchestration
-- ============================================================================

function M.create(parent)
    layout = qt_constants.WIDGETS.CREATE_VBOX(parent)
    tab_container = qt_constants.WIDGETS.CREATE_WIDGET(layout)

    tab_label = qt_constants.WIDGETS.CREATE_LABEL(tab_container)
    qt_constants.LAYOUT.ADD_WIDGET(layout, tab_container)

    M.project_title_widget = tab_label
    if M.pending_project_title then
        local pending = M.pending_project_title
        M.pending_project_title = nil
        if qt_constants.PROPERTIES.SET_TEXT then
            qt_constants.PROPERTIES.SET_TEXT(tab_label, pending)
        end
    end

    tree_context = {
        qt_constants = qt_constants,
        ui_constants = ui_constants,
        register_handler = register_handler,
        resolve_tree_item = resolve_tree_item,
        set_is_restoring_selection = function(v)
            is_restoring_selection = v
        end,
    }

    browser_tree.create_tree(tree_context)
    browser_tree.populate_tree(tree_context)

    browser_actions.setup(tree_context)

    return layout
end

function M.refresh()
    if not tree_context then return end
    browser_tree.populate_tree(tree_context)
end

function M.get_focus_widgets()
    return { tree_context.tree_widget }
end

-- ============================================================================
-- Selection & activation coordination
-- ============================================================================

local function selection_context()
    return {
        tree_widget = tree_context.tree_widget,
        get_selected_item = M.get_selected_item,
        focus_master_clip = M.focus_master_clip,
        focus_sequence = M.focus_sequence,
        focus_bin = M.focus_bin,
    }
end

local function activate_item(item_info)
    if not item_info then return end
    browser_state.activate_item(item_info, selection_context())
end

local function apply_single_selection(info)
    if not info then return end
    browser_state.apply_single_selection(info, selection_context())
end

local function update_selection_state(info)
    if is_restoring_selection then return end
    browser_state.update_selection_state(info, selection_context())
end

function M.activate_selection()
    local info = M.get_selected_item()
    activate_item(info)
    return true
end

-- ============================================================================
-- Rename / inline-edit workflow
-- ============================================================================

local function finalize_pending_rename(new_name)
    browser_actions.finalize_pending_rename(new_name)
end

local function handle_tree_editor_closed(event)
    finalize_pending_rename(event.text)
end

local function handle_tree_item_changed(event)
    update_selection_state(event.info)
end

function M.start_inline_rename()
    browser_actions.start_inline_rename()
end

-- ============================================================================
-- Cross-boundary handlers (tree ↔ state ↔ actions)
-- ============================================================================

handle_tree_drop = function(event)
    local info = browser_tree.lookup_item_by_tree_id(tree_context, event.tree_id)
    if not info then return end
    browser_actions.handle_drop(info, event)
end

handle_tree_key_event = function(event)
    local action = keymap.map_key_event(event)
    if action then
        browser_actions.handle_key_action(action)
        return true
    end
end

-- ============================================================================
-- Public module API
-- ============================================================================

function M.get_selected_item()
    return browser_state.get_selected_item()
end

function M.get_selected_bin()
    return browser_state.get_selected_bin()
end

function M.get_selected_master_clip()
    return browser_state.get_selected_master_clip()
end

function M.get_selected_media()
    return browser_state.get_selected_media()
end

function M.get_selection_snapshot()
    return browser_state.get_selection_snapshot()
end

function M.set_project_title(name)
    if M.project_title_widget and qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(M.project_title_widget, name)
    else
        M.pending_project_title = name
    end
end

function M.focus_master_clip(master_clip_id, opts)
    browser_state.focus_master_clip(master_clip_id, opts)
end

function M.focus_bin(bin_id, opts)
    browser_state.focus_bin(bin_id, opts)
end

function M.focus_sequence(sequence_id, opts)
    browser_state.focus_sequence(sequence_id, opts)
end

command_manager.register_executor(ACTIVATE_COMMAND, function()
    local ok, err = M.activate_selection()
    if not ok and err then
        logger.warn("project_browser", tostring(err))
    end
    return ok and true or false
end)

command_scope.register(ACTIVATE_COMMAND, {scope = "panel", panel_id = "project_browser"})

return M
