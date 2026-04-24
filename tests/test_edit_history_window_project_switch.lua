#!/usr/bin/env luajit
-- A project switch (Open, New, DRP re-import overwriting the current
-- .jvp) must clear the edit-history window's tree immediately. If the
-- new project has no commands yet, the tree must not keep displaying
-- entries from the pre-switch project.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Stub Qt bindings enough that edit_history_window.show() runs without
-- real widgets. We only need to count CLEAR_TREE / ADD_TREE_ITEM calls.
local tree_state = { cleared = 0, added = {} }
local function fake_widget(kind) return { _kind = kind } end

_G.qt_create_single_shot_timer = function() end

package.loaded["core.qt_constants"] = {
    WIDGET = {
        CREATE_WINDOW = function() return fake_widget("window") end,
        CREATE_TOOL_WINDOW = function() return fake_widget("tool_window") end,
        SET_WINDOW_FLAGS = function() end,
        CREATE       = function() return fake_widget("plain") end,
        CREATE_TREE  = function() return fake_widget("tree") end,
    },
    LAYOUT = {
        CREATE_VBOX  = function() return fake_widget("vbox") end,
        SET_ON_WIDGET = function() end,
        ADD_WIDGET    = function() end,
        SET_CENTRAL_WIDGET = function() end,
    },
    PROPERTIES = {
        SET_WINDOW_TITLE = function() end,
        SET_TITLE        = function() end,
        GET_GEOMETRY = function() return 0, 0, 400, 600 end,
        SET_GEOMETRY = function() end,
        SET_SIZE     = function() end,
    },
    DISPLAY = {
        SHOW = function() end,
        RAISE = function() end,
        ACTIVATE = function() end,
        SET_VISIBLE = function() end,
    },
    CONTROL = {
        ADD_TREE_ITEM = function(_tree, row)
            tree_state.added[#tree_state.added + 1] = row
            return #tree_state.added
        end,
        CLEAR_TREE = function()
            tree_state.cleared = tree_state.cleared + 1
            tree_state.added = {}
        end,
        SET_TREE_HEADER_LABELS = function() end,
        SET_TREE_HEADERS       = function() end,
        SET_LAYOUT_SPACING     = function() end,
        SET_LAYOUT_MARGINS     = function() end,
        SET_TREE_COLUMN_WIDTH  = function() end,
        SET_TREE_INDENTATION   = function() end,
        SET_TREE_EXPANDS_ON_DOUBLE_CLICK = function() end,
        SET_TREE_DOUBLE_CLICK_HANDLER = function() end,
        SET_TREE_SELECTION_HANDLER    = function() end,
        SET_TREE_KEY_HANDLER          = function() end,
        SET_TREE_ITEM_DATA            = function() end,
        SET_TREE_CURRENT_ITEM         = function() end,
    },
    SIGNAL = {
        SET_GEOMETRY_CHANGE_HANDLER = function() end,
        SET_CLOSE_HANDLER           = function() end,
    },
}

-- Stub database module lookups used by create_window for saved geometry.
package.loaded["core.database"] = {
    get_current_project_id = function() return "proj" end,
    get_project_setting    = function() return nil end,
    set_project_setting    = function() end,
}

-- A fake command_manager exposing just what the window reads.
local fake_cm = { _entries = {}, _current = 0 }
function fake_cm:list_history_entries() return self._entries, self._current end
function fake_cm.add_listener() return 1 end
function fake_cm.remove_listener() end

-- Old-project entries → open window → expect 2 tree rows.
fake_cm._entries = {
    { sequence_number = 1, command_type = "NewBin",      label = "NewBin" },
    { sequence_number = 2, command_type = "RelinkClips", label = "Relink Clips" },
}
fake_cm._current = 2

require("ui.edit_history_window").show(fake_cm, fake_widget("parent"))

assert(#tree_state.added == 2, string.format(
    "pre-switch: expected 2 tree entries, got %d", #tree_state.added))
local clears_before = tree_state.cleared

-- Simulate project switch: the new project has a different, empty history.
fake_cm._entries = {}
fake_cm._current = 0

require("core.signals").emit("project_changed", "new-project-id")

assert(tree_state.cleared > clears_before,
    "tree was not cleared on project_changed")
assert(#tree_state.added == 0, string.format(
    "post-switch: expected empty tree, got %d entries", #tree_state.added))

print("✅ test_edit_history_window_project_switch.lua passed")
