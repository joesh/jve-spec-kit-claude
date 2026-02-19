--- welcome_screen: modal startup dialog shown when no last project exists
--
-- Responsibilities:
-- - Display recent projects list (tree widget, double-click to open)
-- - Provide New Project, Open Project, and Quit buttons
-- - Return action table describing user's choice
--
-- Non-goals:
-- - Project creation (delegated to new_project command)
-- - File browsing (delegated to file_browser module)
--
-- Invariants:
-- - show() is blocking (modal dialog)
-- - Returns action table or nil (Quit)
-- - Recent list filters missing files (via recent_projects.load())
--
-- Size: ~120 LOC
-- Volatility: low
--
-- @file welcome_screen.lua
local M = {}
local logger = require("core.logger")
local recent_projects = require("core.recent_projects")

--- Show the welcome screen modal dialog.
-- @return table|nil: {action="open", path=...}, {action="new"}, {action="open_browse"}, or nil (Quit)
function M.show()
    local qt = require("core.qt_constants")

    -- Dialog result captured by button/double-click handlers
    local result = nil

    -- Create dialog
    local dialog = qt.DIALOG.CREATE("JVE Editor", 600, 400)

    -- Main layout: horizontal (left=recent list, right=buttons)
    local main_layout = qt.LAYOUT.CREATE_HBOX()

    -- -----------------------------------------------------------------------
    -- Left side: Recent Projects
    -- -----------------------------------------------------------------------
    local left_layout = qt.LAYOUT.CREATE_VBOX()
    local title_label = qt.WIDGET.CREATE_LABEL("Recent Projects")
    qt.LAYOUT.ADD_WIDGET(left_layout, title_label)

    local tree = qt.WIDGET.CREATE_TREE()
    qt.CONTROL.SET_TREE_HEADERS(tree, {"Project", "Path"})
    qt.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 0, 200)

    -- Populate from recent projects
    local entries = recent_projects.load()
    local item_paths = {}  -- item_id → path

    for _, entry in ipairs(entries) do
        local display_name = entry.name or "Untitled"
        local display_path = entry.path or ""
        local item_id = qt.CONTROL.ADD_TREE_ITEM(tree, {display_name, display_path})
        if item_id and item_id ~= -1 then
            item_paths[item_id] = entry.path
            qt.CONTROL.SET_TREE_ITEM_DATA(tree, item_id, "path", entry.path)
        end
    end

    -- Double-click handler: open selected project
    local dbl_click_name = "__welcome_screen_double_click"
    _G[dbl_click_name] = function(item_id, _col)
        local path = item_paths[item_id]
        if path then
            result = { action = "open", path = path }
            qt.DIALOG.CLOSE(dialog, true)
        end
    end
    qt.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER(tree, dbl_click_name)

    qt.LAYOUT.ADD_WIDGET(left_layout, tree)

    -- -----------------------------------------------------------------------
    -- Right side: Buttons
    -- -----------------------------------------------------------------------
    local right_layout = qt.LAYOUT.CREATE_VBOX()
    qt.LAYOUT.ADD_STRETCH(right_layout)

    local new_btn = qt.WIDGET.CREATE_BUTTON("New Project...")
    local open_btn = qt.WIDGET.CREATE_BUTTON("Open Project...")
    local quit_btn = qt.WIDGET.CREATE_BUTTON("Quit")

    local new_handler = "__welcome_screen_new"
    _G[new_handler] = function()
        result = { action = "new" }
        qt.DIALOG.CLOSE(dialog, true)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(new_btn, new_handler)

    local open_handler = "__welcome_screen_open"
    _G[open_handler] = function()
        result = { action = "open_browse" }
        qt.DIALOG.CLOSE(dialog, true)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(open_btn, open_handler)

    local quit_handler = "__welcome_screen_quit"
    _G[quit_handler] = function()
        result = nil
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(quit_btn, quit_handler)

    qt.LAYOUT.ADD_WIDGET(right_layout, new_btn)
    qt.LAYOUT.ADD_SPACING(right_layout, 8)
    qt.LAYOUT.ADD_WIDGET(right_layout, open_btn)
    qt.LAYOUT.ADD_SPACING(right_layout, 24)
    qt.LAYOUT.ADD_WIDGET(right_layout, quit_btn)
    qt.LAYOUT.ADD_STRETCH(right_layout)

    -- -----------------------------------------------------------------------
    -- Assemble
    -- -----------------------------------------------------------------------
    qt.LAYOUT.ADD_LAYOUT(main_layout, left_layout)
    qt.LAYOUT.ADD_LAYOUT(main_layout, right_layout)
    qt.DIALOG.SET_LAYOUT(dialog, main_layout)

    -- Show (blocking)
    logger.info("welcome_screen", "Showing welcome screen")
    qt.DIALOG.SHOW(dialog)

    -- Cleanup globals
    _G[dbl_click_name] = nil
    _G[new_handler] = nil
    _G[open_handler] = nil
    _G[quit_handler] = nil

    return result
end

return M
