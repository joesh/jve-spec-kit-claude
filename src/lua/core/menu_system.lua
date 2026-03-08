--- Menu System - XML-driven menu configuration with pure command dispatch
--
-- Responsibilities:
-- - Parse menus.xml and create QMenuBar with nested menus
-- - Register command metadata for shortcut editor UI
-- - Query keyboard_shortcut_registry for shortcut display text
-- - On click: dispatch to command_manager.execute(command_name, params)
--
-- Non-goals:
-- - Business logic (moved to commands)
-- - Dialog handling (moved to commands)
-- - Shortcut definitions (TOML is sole authority)
--
-- Invariants:
-- - All menu items dispatch to commands (except Insert/Overwrite)
-- - Menu item name = command name (no indirection)
-- - menus.xml defines structure only; shortcuts come from keybinding registry
--
-- @file menu_system.lua
local M = {}

local lxp = require("lxp")
local keyboard_shortcut_registry = require("core.keyboard_shortcut_registry")
local log = require("core.logger").for_area("media")

local command_manager = nil
local main_window = nil

local actions_by_command = {}
local undo_listener_token = nil
local update_undo_redo_actions  -- forward declaration

-- Qt bindings (loaded from qt_constants global)
local qt = {
    GET_MENU_BAR = qt_constants.MENU.GET_MENU_BAR,
    CREATE_MENU = qt_constants.MENU.CREATE_MENU,
    ADD_MENU_TO_BAR = qt_constants.MENU.ADD_MENU_TO_BAR,
    ADD_SUBMENU = qt_constants.MENU.ADD_SUBMENU,
    CREATE_MENU_ACTION = qt_constants.MENU.CREATE_MENU_ACTION,
    CONNECT_MENU_ACTION = qt_constants.MENU.CONNECT_MENU_ACTION,
    ADD_MENU_SEPARATOR = qt_constants.MENU.ADD_MENU_SEPARATOR,
    SET_ACTION_ENABLED = qt_constants.MENU.SET_ACTION_ENABLED,
    SET_ACTION_CHECKED = qt_constants.MENU.SET_ACTION_CHECKED,
    SET_ACTION_TEXT = qt_constants.MENU.SET_ACTION_TEXT,
    SET_ACTION_SHORTCUT = qt_constants.MENU.SET_ACTION_SHORTCUT
}

--- Initialize menu system
-- @param window userdata: QMainWindow instance
-- @param cmd_mgr table: Command manager instance
-- @param proj_browser table: Project browser instance (optional, now uses ui_state)
function M.init(window, cmd_mgr, proj_browser)
    main_window = window
    command_manager = cmd_mgr

    -- Initialize ui_state so commands can access main_window (only if window provided)
    if window then
        local ui_state = require("ui.ui_state")
        ui_state.init(window, { project_browser = proj_browser })
    end

    if undo_listener_token and command_manager and command_manager.remove_listener then
        command_manager.remove_listener(undo_listener_token)
        undo_listener_token = nil
    end

    if command_manager and command_manager.add_listener then
        undo_listener_token = command_manager.add_listener(function(event)
            if not event or not event.event then
                return
            end
            if event.event == "execute" or event.event == "undo" or event.event == "redo" then
                update_undo_redo_actions()
            end
        end)
    end

    if update_undo_redo_actions then
        update_undo_redo_actions()
    end
end

--- Set timeline panel reference (called after timeline is created)
-- @param timeline_pnl table: Timeline panel instance
function M.set_timeline_panel(timeline_pnl)
    local ui_state = require("ui.ui_state")
    ui_state.set_timeline_panel(timeline_pnl)
end

--- Parse XML file using LuaExpat
-- @param xml_path string: Path to menus.xml
-- @return table|nil: Parsed XML tree, or nil on error
-- @return string|nil: Error message if failed
local function parse_xml_file(xml_path)
    local file = io.open(xml_path, "r")
    if not file then
        return nil, "Failed to open menu XML file: " .. xml_path
    end

    local content = file:read("*all")
    file:close()

    -- Build XML tree using stack-based parser
    local stack = {{tag = "root", children = {}, attrs = {}}}
    local current = stack[1]

    local parser = lxp.new({
        StartElement = function(parser, name, attrs)
            local elem = {tag = name, attrs = attrs or {}, children = {}}
            table.insert(current.children, elem)
            table.insert(stack, elem)
            current = elem
        end,
        EndElement = function(parser, name)
            table.remove(stack)
            current = stack[#stack]
        end
    })

    local success, err = parser:parse(content)
    if not success then
        return nil, "XML parse error: " .. tostring(err)
    end

    parser:parse()  -- Finalize
    parser:close()

    return stack[1], nil
end

--- Find element by tag name
-- @param elem table: XML element
-- @param tag_name string: Tag to find
-- @return table|nil: First matching element
local function find_element(elem, tag_name)
    if elem.tag == tag_name then
        return elem
    end

    for _, child in ipairs(elem.children) do
        local found = find_element(child, tag_name)
        if found then return found end
    end

    return nil
end

local function copy_path(path)
    local result = {}
    for index, value in ipairs(path) do
        result[index] = value
    end
    return result
end

--- Register command metadata (for shortcut editor UI). No shortcuts — TOML is sole authority.
local function register_menu_command(menu_path, attrs)
    assert(type(menu_path) == "table" and #menu_path > 0, "Menu path required for command registration")
    assert(type(attrs) == "table", "Menu item attributes required for command registration")

    local command_id = attrs.command
    local item_name = attrs.name
    assert(type(command_id) == "string" and command_id ~= "", string.format("Menu item '%s' missing command attribute", tostring(item_name)))
    assert(type(item_name) == "string" and item_name ~= "", "Menu item missing name for command " .. command_id)

    local category = table.concat(menu_path, " ▸ ")
    local description = attrs.description or ""

    -- Only register once (idempotent)
    if not keyboard_shortcut_registry.commands[command_id] then
        keyboard_shortcut_registry.register_command({
            id = command_id,
            category = category,
            name = item_name,
            description = description,
        })
    end
end

--- Convert platform-agnostic shortcut to Qt format
-- Cmd -> Ctrl for Qt (on macOS, Qt maps Ctrl to Command key)
-- @param shortcut string: Shortcut string (e.g., "Cmd+S")
-- @return string: Qt-compatible shortcut
local function convert_shortcut(shortcut)
    if not shortcut or shortcut == "" then
        return ""
    end
    return shortcut:gsub("Cmd", "Ctrl")
end

--- Parse parameter string to Lua table
-- Handles simple JSON-like syntax: {delta_ms=-33}
-- @param params_str string: Parameter string
-- @return table: Parsed parameters
local function parse_params(params_str)
    if not params_str or params_str == "" then
        return {}
    end

    -- Simple parser for {key=value, key2=value2} format
    local params = {}
    local content = params_str:match("^%s*{(.+)}%s*$")
    if not content then
        return params
    end

    for pair in content:gmatch("[^,]+") do
        local key, value = pair:match("^%s*([%w_]+)%s*=%s*(.+)%s*$")
        if key and value then
            -- Try to parse as number
            local num = tonumber(value)
            if num then
                params[key] = num
            else
                -- Remove quotes from string values
                params[key] = value:match("^['\"](.+)['\"]$") or value
            end
        end
    end

    return params
end

local function register_action_for_command(command_name, action)
    if not command_name or command_name == "" or not action then
        return
    end
    local actions = actions_by_command[command_name]
    if not actions then
        actions = {}
        actions_by_command[command_name] = actions
    end
    table.insert(actions, action)
end

local function set_actions_enabled_for_command(command_name, enabled)
    local actions = actions_by_command[command_name]
    if not actions then
        return
    end
    for _, action in ipairs(actions) do
        qt.SET_ACTION_ENABLED(action, enabled and true or false)
    end
end

local function set_actions_text_for_command(command_name, text)
    if not qt.SET_ACTION_TEXT then
        return
    end
    local actions = actions_by_command[command_name]
    if not actions then
        return
    end
    for _, action in ipairs(actions) do
        qt.SET_ACTION_TEXT(action, text)
    end
end

update_undo_redo_actions = function()
    if not command_manager or not command_manager.can_undo or not command_manager.can_redo then
        set_actions_enabled_for_command("Undo", false)
        set_actions_enabled_for_command("Redo", false)
        set_actions_text_for_command("Undo", "Undo")
        set_actions_text_for_command("Redo", "Redo")
        return
    end
    local can_undo = command_manager.can_undo()
    local can_redo = command_manager.can_redo()

    set_actions_enabled_for_command("Undo", can_undo)
    set_actions_enabled_for_command("Redo", can_redo)

    local undo_label = "Undo"
    if can_undo and command_manager.get_last_command then
        local cmd = command_manager.get_last_command(nil)
        if cmd and cmd.get_display_label then
            undo_label = "Undo " .. cmd:get_display_label()
        end
    end

    local redo_label = "Redo"
    if can_redo and command_manager.get_next_redo_command then
        local cmd = command_manager.get_next_redo_command(nil)
        if cmd and cmd.get_display_label then
            redo_label = "Redo " .. cmd:get_display_label()
        end
    end

    set_actions_text_for_command("Undo", undo_label)
    set_actions_text_for_command("Redo", redo_label)
end

--- Get active project ID from timeline or database
local function get_active_project_id()
    local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
    if ui_state_ok then
        local timeline_panel = ui_state.get_timeline_panel()
        if timeline_panel and timeline_panel.get_state then
            local state = timeline_panel.get_state()
            if state and state.get_project_id then
                local project_id = state.get_project_id()
                if project_id and project_id ~= "" then
                    return project_id
                end
            end
        end
    end

    local database = require("core.database")
    if database and database.get_current_project_id then
        local project_id = database.get_current_project_id()
        if project_id and project_id ~= "" then
            return project_id
        end
    end

    -- NSF-OK: nil project_id is valid during startup before any project is loaded
    return nil
end

--- Create menu action callback - Pure command dispatch
-- @param command_name string: Command to execute
-- @param params table: Command parameters
-- @return function: Callback function
local function create_action_callback(command_name, params)
    return function()
        assert(command_manager,
            "create_action_callback: menu system not initialized with command manager")

        log.event("Menu clicked: %s", tostring(command_name))

        -- Special handling for commands that need external context gathering
        if command_name == "Insert" or command_name == "Overwrite" then
            local project_browser = require("ui.project_browser")
            project_browser.add_selected_to_timeline(command_name, {advance_playhead = true})
            return
        end

        -- Pure command dispatch for everything else
        -- Copy params to avoid mutating the closure's table (project_id would become stale)
        local project_id = get_active_project_id()
        local command_params = {}
        if params then
            for k, v in pairs(params) do command_params[k] = v end
        end
        command_params.project_id = command_params.project_id or project_id

		local result_value
		-- Headless tests inject a minimal command_manager stub (execute-only).
		if type(command_manager.execute_ui) == "function" then
			result_value = command_manager.execute_ui(command_name, command_params)
		else
			result_value = command_manager.execute(command_name, command_params)
		end

        if result_value and not result_value.success and not result_value.cancelled then
            log.error("Command '%s' returned error: %s", tostring(command_name), tostring(result_value.error_message or "unknown"))
        elseif result_value and result_value.cancelled then
            log.event("Command '%s' cancelled by user", tostring(command_name))
        else
            log.event("Command '%s' executed successfully", tostring(command_name))
        end
    end
end

-- Test helper: expose action callback creation without Qt wiring.
function M._test_get_action_callback(command_name, params)
    return create_action_callback(command_name, params)
end

--- Build QMenu from XML element (recursive)
-- @param menu_elem table: XML <menu> element
-- @param parent_menu userdata: Qt QMenu or QMenuBar parent
local function build_menu(menu_elem, parent_menu, menu_path)
    assert(menu_elem.attrs ~= nil, "Menu element missing attributes")
    assert(type(menu_elem.attrs.name) == "string" and menu_elem.attrs.name ~= "", "Menu element missing name attribute")
    local menu_name = menu_elem.attrs.name
    local current_path = copy_path(menu_path)
    table.insert(current_path, menu_name)

    local menu = qt.CREATE_MENU(parent_menu, menu_name)

    for _, child in ipairs(menu_elem.children) do
        if child.tag == "item" then
            assert(child.attrs ~= nil, string.format("Menu item under '%s' missing attributes", menu_name))
            register_menu_command(current_path, child.attrs)

            local item_name = child.attrs.name
            local command_name = child.attrs.command
            local checkable = child.attrs.checkable == "true"
            local params = {}
            if child.attrs.params ~= nil then
                params = parse_params(child.attrs.params)
            end

            -- No shortcut passed — display text set later by update_shortcut_display()
            local action = qt.CREATE_MENU_ACTION(menu, item_name, "", checkable)

            if command_name then
                qt.CONNECT_MENU_ACTION(action, create_action_callback(command_name, params))
                register_action_for_command(command_name, action)
            end

        elseif child.tag == "separator" then
            qt.ADD_MENU_SEPARATOR(menu)

        elseif child.tag == "menu" then
            local submenu = build_menu(child, menu, current_path)
            qt.ADD_SUBMENU(menu, submenu)
        end
    end

    return menu
end

--- Update menu shortcut display text from keybinding registry.
-- Iterates all registered command actions and sets QAction shortcut
-- from the TOML keybinding registry.
function M.update_shortcut_display()
    if not qt.SET_ACTION_SHORTCUT then
        return
    end

    local keybindings = keyboard_shortcut_registry.keybindings
    -- Build reverse map: command_name → first shortcut string
    local command_shortcuts = {}
    for _, binding in pairs(keybindings) do
        if not command_shortcuts[binding.command_name] and binding.shortcut then
            command_shortcuts[binding.command_name] = binding.shortcut.string
        end
    end

    for command_name, actions in pairs(actions_by_command) do
        local shortcut_str = command_shortcuts[command_name]
        if shortcut_str then
            local qt_shortcut = convert_shortcut(shortcut_str)
            for _, action in ipairs(actions) do
                qt.SET_ACTION_SHORTCUT(action, qt_shortcut)
            end
        end
    end
end

--- Load menus from XML file
-- @param xml_path string: Path to menus.xml
-- @return boolean: Success flag
-- @return string|nil: Error message if failed
function M.load_from_file(xml_path)
    if not main_window then
        return false, "Menu system not initialized - call init() first"
    end

    actions_by_command = {}

    -- Parse XML
    local root, err = parse_xml_file(xml_path)
    if not root then
        return false, err
    end

    local menus_elem = find_element(root, "menus")
    if not menus_elem then
        return false, "No <menus> root element found"
    end

    local menu_bar = qt.GET_MENU_BAR(main_window)

    for _, child in ipairs(menus_elem.children) do
        if child.tag == "menu" then
            local menu = build_menu(child, menu_bar, {})
            qt.ADD_MENU_TO_BAR(menu_bar, menu)
        end
    end

    log.event("Loaded %d menus from %s", #menus_elem.children, tostring(xml_path))
    update_undo_redo_actions()
    return true
end

--- Update menu item enabled state
-- @param command_name string: Command name
-- @param enabled boolean: Whether item should be enabled
function M.set_item_enabled(command_name, enabled)
    set_actions_enabled_for_command(command_name, enabled ~= false)
end

--- Update menu item checked state
-- @param command_name string: Command name
-- @param checked boolean: Whether item should be checked
function M.set_item_checked(command_name, checked)
    local actions = actions_by_command[command_name]
    if not actions then
        return
    end
    for _, action in ipairs(actions) do
        qt.SET_ACTION_CHECKED(action, checked and true or false)
    end
end

return M
