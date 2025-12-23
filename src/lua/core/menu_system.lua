--- Menu System - XML-driven menu configuration
-- Parses menus.xml and creates QMenuBar with nested menus
--
-- XML Format:
--   <menus>
--     <menu name="File">
--       <item name="Open" command="OpenProject" shortcut="Cmd+O"/>
--       <separator/>
--       <menu name="Import">
--         <item name="Media..." command="ImportMedia"/>
--       </menu>
--     </menu>
--   </menus>
--
-- Usage:
--   local menu_system = require("core.menu_system")
--   menu_system.init(main_window, command_manager)
--   menu_system.load_from_file("menus.xml")

local M = {}

local lxp = require("lxp")
local keyboard_shortcut_registry = require("core.keyboard_shortcut_registry")
local keyboard_shortcuts = require("core.keyboard_shortcuts")
local command_manager = nil
local main_window = nil
local project_browser = nil
local timeline_panel = nil
local clipboard_actions = require("core.clipboard_actions")
local profile_scope = require("core.profile_scope")
local Rational = require("core.rational")
local logger = require("core.logger")
local project_open = require("core.project_open")

local registered_shortcut_commands = {}
local defaults_initialized = false
local actions_by_command = {}
local undo_listener_token = nil
local update_undo_redo_actions  -- forward declaration

local function get_active_project_id()
    if timeline_panel and timeline_panel.get_state then
        local state = timeline_panel.get_state()
        if state and state.get_project_id then
            local project_id = state.get_project_id()
            if project_id and project_id ~= "" then
                return project_id
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

    return nil
end

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
    SET_ACTION_TEXT = qt_constants.MENU.SET_ACTION_TEXT
}

--- Initialize menu system
-- @param window userdata: QMainWindow instance
-- @param cmd_mgr table: Command manager instance
-- @param proj_browser table: Project browser instance (optional)
function M.init(window, cmd_mgr, proj_browser)
    main_window = window
    command_manager = cmd_mgr
    project_browser = proj_browser

    if undo_listener_token and command_manager and command_manager.remove_listener then
        command_manager.remove_listener(undo_listener_token)
        undo_listener_token = nil
    end

    if command_manager and command_manager.add_listener then
        undo_listener_token = command_manager.add_listener(profile_scope.wrap("menu_system.undo_listener", function(event)
            if not event or not event.event then
                return
            end
            if event.event == "execute" or event.event == "undo" or event.event == "redo" then
                update_undo_redo_actions()
            end
        end))
    end

    if update_undo_redo_actions then
        update_undo_redo_actions()
    end
end

--- Set timeline panel reference (called after timeline is created)
-- @param timeline_pnl table: Timeline panel instance
function M.set_timeline_panel(timeline_pnl)
    timeline_panel = timeline_pnl
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

local function trim_whitespace(value)
    assert(value ~= nil, "trim_whitespace requires a value")
    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == nil then
        return ""
    end
    return trimmed
end

local function register_menu_shortcut(menu_path, attrs)
    assert(type(menu_path) == "table" and #menu_path > 0, "Menu path required for shortcut registration")
    assert(type(attrs) == "table", "Menu item attributes required for shortcut registration")

    local command_id = attrs.command
    local item_name = attrs.name
    assert(type(command_id) == "string" and command_id ~= "", string.format("Menu item '%s' missing command attribute", tostring(item_name)))
    assert(type(item_name) == "string" and item_name ~= "", "Menu item missing name for command " .. command_id)

    local category = table.concat(menu_path, " ▸ ")
    local description = attrs.description
    if description == nil then
        description = ""
    end

    local default_shortcuts = {}
    if attrs.shortcut ~= nil then
        local shortcut_value = trim_whitespace(attrs.shortcut)
        if shortcut_value ~= "" then
            table.insert(default_shortcuts, shortcut_value)
        end
    end

    if not registered_shortcut_commands[command_id] then
        keyboard_shortcut_registry.register_command({
            id = command_id,
            category = category,
            name = item_name,
            description = description,
            default_shortcuts = default_shortcuts
        })
        registered_shortcut_commands[command_id] = true
        if defaults_initialized and #default_shortcuts > 0 then
            for _, shortcut_value in ipairs(default_shortcuts) do
                local assigned, assign_err = keyboard_shortcut_registry.assign_shortcut(command_id, shortcut_value)
                if not assigned then
                    error(string.format("Failed to assign default shortcut '%s' to command '%s': %s", shortcut_value, command_id, tostring(assign_err)))
                end
            end
        end
        return
    end

    if #default_shortcuts == 0 then
        return
    end

    local command = keyboard_shortcut_registry.commands[command_id]
    assert(command ~= nil, "Registered command table missing for " .. command_id)

    local shortcut_to_add = default_shortcuts[1]
    for _, existing in ipairs(command.default_shortcuts) do
        if existing == shortcut_to_add then
            shortcut_to_add = nil
            break
        end
    end

    if shortcut_to_add ~= nil then
        table.insert(command.default_shortcuts, shortcut_to_add)
        if defaults_initialized then
            local assigned, assign_err = keyboard_shortcut_registry.assign_shortcut(command_id, shortcut_to_add)
            if not assigned then
                error(string.format("Failed to assign default shortcut '%s' to command '%s': %s", shortcut_to_add, command_id, tostring(assign_err)))
            end
        end
    end
end

--- Convert platform-agnostic shortcut to Qt format
-- Cmd -> Meta on macOS, Ctrl on Windows/Linux
-- @param shortcut string: Shortcut string (e.g., "Cmd+S")
-- @return string: Qt-compatible shortcut
local function convert_shortcut(shortcut)
    if not shortcut or shortcut == "" then
        return ""
    end

    -- Qt on macOS: "Ctrl" in shortcuts automatically maps to Command key
    -- Qt on Windows/Linux: "Ctrl" maps to Control key
    -- So "Cmd" -> "Ctrl" works correctly on all platforms!
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

--- Create menu action callback
-- @param command_name string: Command to execute
-- @param params table: Command parameters
-- @return function: Callback function
local function create_action_callback(command_name, params)
    return function()
        if not command_manager then
            logger.error("menu", "Menu system not initialized with command manager")
            return
        end

        logger.debug("menu", string.format("Menu clicked: %s", tostring(command_name)))

        -- Handle special commands that aren't normal execute() calls
        if command_name == "Undo" then
            if command_manager.can_undo and not command_manager.can_undo() then
                return
            end
            logger.debug("menu", "Calling command_manager.undo()")
            command_manager.undo()
            update_undo_redo_actions()
        elseif command_name == "Redo" then
            if command_manager.can_redo and not command_manager.can_redo() then
                return
            end
            logger.debug("menu", "Calling command_manager.redo()")
            command_manager.redo()
            update_undo_redo_actions()
        elseif command_name == "Quit" then
            logger.info("menu", "Quitting application")
            local ok, err = pcall(function()
                local database = require("core.database")
                if database and database.shutdown then
                    local success, message = database.shutdown({ best_effort = true })
                    if not success then
                        error(message or "database.shutdown failed")
                    end
                end
            end)
            if not ok then
                logger.error("menu", "Quit shutdown failed: " .. tostring(err))
            end
            os.exit(0)
        elseif command_name == "OpenProject" then
            local home = os.getenv("HOME") or ""
            local default_dir = home ~= "" and (home .. "/Documents/JVE Projects") or ""
            local project_path = qt_constants.FILE_DIALOG.OPEN_FILE(
                main_window,
                "Open Project",
                "JVE Project Files (*.jvp);;All Files (*)",
                default_dir
            )

            if not project_path or project_path == "" then
                return
            end

            local database = require("core.database")
            local opened = project_open.open_project_database_or_prompt_cleanup(database, qt_constants, project_path, main_window)
            if not opened then
                qt_constants.DIALOG.SHOW_CONFIRM({
                    parent = main_window,
                    title = "Open Project Failed",
                    message = "Failed to open project database:\n" .. tostring(project_path),
                    confirm_text = "OK",
                    cancel_text = "Cancel",
                    icon = "warning",
                    default_button = "confirm"
                })
                return
            end

            local db = database.get_connection()
            assert(db, "OpenProject: database connection is nil after open")

            local sequence_id, project_id
            local stmt = db:prepare([[
                SELECT id, project_id
                FROM sequences
                ORDER BY modified_at DESC, created_at DESC, id ASC
                LIMIT 1
            ]])
            assert(stmt, "OpenProject: failed to prepare active sequence query")
            local ok = stmt:exec() and stmt:next()
            if ok then
                sequence_id = stmt:value(0)
                project_id = stmt:value(1)
            end
            stmt:finalize()

            assert(sequence_id and sequence_id ~= "", "OpenProject: no sequences found in database (path=" .. tostring(project_path) .. ")")
            assert(project_id and project_id ~= "", "OpenProject: active sequence missing project_id (sequence_id=" .. tostring(sequence_id) .. ")")

            command_manager.init(db, sequence_id, project_id)

            if timeline_panel and timeline_panel.load_sequence then
                timeline_panel.load_sequence(sequence_id)
            end

            if project_browser and project_browser.refresh then
                project_browser.refresh()
            end

            if project_browser and project_browser.focus_sequence then
                project_browser.focus_sequence(sequence_id)
            end

            local Project = require("models.project")
            local project = Project.load(project_id)
            assert(project and project.name and project.name ~= "", "OpenProject: project name missing (project_id=" .. tostring(project_id) .. ")")
            if qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_TITLE then
                qt_constants.PROPERTIES.SET_TITLE(main_window, project.name)
            end

            update_undo_redo_actions()
        elseif command_name == "GoToTimecode" then
            assert(timeline_panel and timeline_panel.focus_timecode_entry, "GoToTimecode requires timeline_panel.focus_timecode_entry")
            timeline_panel.focus_timecode_entry()
        elseif command_name == "EditHistory" then
            local edit_history_window = require("ui.edit_history_window")
            edit_history_window.show(command_manager, main_window)
        elseif command_name == "ShowRelinkDialog" then
            local database = require("core.database")
            local db = database and database.get_connection and database.get_connection()
            if not db then
                logger.error("menu", "ShowRelinkDialog: database not available")
                return
            end

            local project_id = get_active_project_id()
            assert(project_id and project_id ~= "", "ShowRelinkDialog: active project_id unavailable")
            local media_relinker = require("core.media_relinker")
            local offline = media_relinker.find_offline_media(db, project_id)
            if not offline or #offline == 0 then
                qt_constants.DIALOG.SHOW_CONFIRM({
                    parent = main_window,
                    title = "Relink Media",
                    message = "No offline media found.",
                    confirm_text = "OK",
                    cancel_text = "Cancel",
                    icon = "information",
                    default_button = "confirm"
                })
                return
            end

            local dir = qt_constants.FILE_DIALOG.OPEN_DIRECTORY(
                main_window,
                "Select Search Directory",
                os.getenv("HOME") or ""
            )
            if not dir or dir == "" then
                return
            end

            local results = media_relinker.batch_relink(offline, {
                search_paths = {dir}
            })

            local relinked = (results and results.relinked) or {}
            local failed = (results and results.failed) or {}
            if #relinked == 0 then
                qt_constants.DIALOG.SHOW_CONFIRM({
                    parent = main_window,
                    title = "Relink Media",
                    message = "No matches found in the selected directory.",
                    confirm_text = "OK",
                    cancel_text = "Cancel",
                    icon = "warning",
                    default_button = "confirm"
                })
                return
            end

            local accepted = qt_constants.DIALOG.SHOW_CONFIRM({
                parent = main_window,
                title = "Relink Media",
                message = string.format("Relink %d media file(s)? (%d could not be matched)", #relinked, #failed),
                confirm_text = "Relink",
                cancel_text = "Cancel",
                icon = "question",
                default_button = "confirm"
            })

            if not accepted then
                return
            end

            local relink_map = {}
            for _, entry in ipairs(relinked) do
                if entry and entry.media and entry.media.id and entry.new_path then
                    relink_map[entry.media.id] = entry.new_path
                end
            end

            local Command = require("command")
            local cmd = Command.create("BatchRelinkMedia", project_id)
            cmd:set_parameter("relink_map", relink_map)
            local ok, result = pcall(function()
                return command_manager.execute(cmd)
            end)
            if not ok then
                logger.error("menu", "ShowRelinkDialog: BatchRelinkMedia threw: " .. tostring(result))
                return
            end
            if not result or not result.success then
                logger.error("menu", "ShowRelinkDialog: BatchRelinkMedia failed: " .. tostring(result and result.error_message or "unknown"))
                return
            end
        elseif command_name == "ManageTags" then
            if project_browser and project_browser.focus_bin then
                project_browser.focus_bin()
            end
            qt_constants.DIALOG.SHOW_CONFIRM({
                parent = main_window,
                title = "Manage Tags",
                message = "Tags are currently managed as bins in the Project Browser.",
                confirm_text = "OK",
                cancel_text = "Cancel",
                icon = "information",
                default_button = "confirm"
            })
        elseif command_name == "ConsolidateMedia" then
            qt_constants.DIALOG.SHOW_CONFIRM({
                parent = main_window,
                title = "Consolidate Media",
                message = "Consolidate Media is not implemented yet.",
                confirm_text = "OK",
                cancel_text = "Cancel",
                icon = "information",
                default_button = "confirm"
            })
        elseif command_name == "ImportMedia" then
            local file_paths = qt_constants.FILE_DIALOG.OPEN_FILES(
                main_window,
                "Import Media Files",
                "Media Files (*.mp4 *.mov *.m4v *.avi *.mkv *.mxf *.wav *.aiff *.mp3);;All Files (*)"
            )

            if file_paths then
                if type(file_paths) == "table" then
                    for i, file_path in ipairs(file_paths) do
                        logger.debug("menu", string.format("ImportMedia[%d]: %s", i, tostring(file_path)))
                        local Command = require("command")
                        local project_id = get_active_project_id()
                        assert(project_id and project_id ~= "", "menu_system: ImportMedia missing active project_id")
                        local cmd = Command.create("ImportMedia", project_id)
                        cmd:set_parameter("file_path", file_path)
                        cmd:set_parameter("project_id", project_id)

                        local success, result = pcall(function()
                            return command_manager.execute(cmd)
                        end)
                        if success then
                            if result and result.success then
                                logger.info("menu", "Imported media: " .. tostring(file_path))
                            else
                                logger.error("menu", "ImportMedia returned error: " .. tostring(result and result.error_message or "unknown"))
                            end
                        else
                            logger.error("menu", "ImportMedia threw: " .. tostring(result))
                        end
                    end

                    -- Refresh project browser to show newly imported media
                    if project_browser then
                        if project_browser.refresh then
                            project_browser.refresh()
                        else
                            logger.warn("menu", "project_browser.refresh is nil")
                        end
                    else
                        logger.warn("menu", "project_browser is nil (menu system not initialized with project browser)")
                    end
                else
                    logger.warn("menu", "ImportMedia file dialog returned non-table value")
                end
            end

        elseif command_name == "ImportFCP7XML" then
            local file_path = qt_constants.FILE_DIALOG.OPEN_FILE(
                main_window,
                "Import Final Cut Pro 7 XML",
                "Final Cut Pro XML (*.xml);;All Files (*)"
            )

            if file_path then
                logger.info("menu", "Importing FCP7 XML: " .. tostring(file_path))
                local Command = require("command")
                local project_id = get_active_project_id()
                assert(project_id and project_id ~= "", "menu_system: ImportFCP7XML missing active project_id")
                local cmd = Command.create("ImportFCP7XML", project_id)
                cmd:set_parameter("xml_path", file_path)
                cmd:set_parameter("project_id", project_id)

                local success, result = pcall(function()
                    return command_manager.execute(cmd)
                end)

                if not success then
                    logger.error("menu", "ImportFCP7XML threw: " .. tostring(result))
                elseif result and not result.success then
                    logger.error("menu", "ImportFCP7XML returned error: " .. tostring(result.error_message or "unknown"))
                else
                    logger.info("menu", "FCP7 XML imported successfully")
                    if project_browser and project_browser.refresh then
                        project_browser.refresh()
                    end
                end
            end

        elseif command_name == "ImportResolveProject" then
            local file_path = qt_constants.FILE_DIALOG.OPEN_FILE(
                main_window,
                "Import Resolve Project (.drp)",
                "Resolve Project Files (*.drp);;All Files (*)"
            )

            if file_path then
                logger.info("menu", "Importing Resolve project: " .. tostring(file_path))
                local Command = require("command")
                local project_id = get_active_project_id()
                assert(project_id and project_id ~= "", "menu_system: ImportResolveProject missing active project_id")
                local cmd = Command.create("ImportResolveProject", project_id)
                cmd:set_parameter("drp_path", file_path)
                cmd:set_parameter("project_id", project_id)

                local success, result = pcall(function()
                    return command_manager.execute(cmd)
                end)
                if not success then
                    logger.error("menu", "ImportResolveProject threw: " .. tostring(result))
                elseif result and not result.success then
                    logger.error("menu", "ImportResolveProject returned error: " .. tostring(result.error_message or "unknown"))
                else
                    logger.info("menu", "Resolve project imported successfully")
                end
            end

        elseif command_name == "ImportResolveDatabase" then
            local file_path = qt_constants.FILE_DIALOG.OPEN_FILE(
                main_window,
                "Import Resolve Database",
                "Database Files (*.db *.sqlite *.resolve);;All Files (*)",
                os.getenv("HOME") .. "/Movies/DaVinci Resolve"
            )

            if file_path then
                logger.info("menu", "Importing Resolve database: " .. tostring(file_path))
                local Command = require("command")
                local project_id = get_active_project_id()
                assert(project_id and project_id ~= "", "menu_system: ImportResolveDatabase missing active project_id")
                local cmd = Command.create("ImportResolveDatabase", project_id)
                cmd:set_parameter("db_path", file_path)
                cmd:set_parameter("project_id", project_id)

                local success, result = pcall(function()
                    return command_manager.execute(cmd)
                end)
                if not success then
                    logger.error("menu", "ImportResolveDatabase threw: " .. tostring(result))
                elseif result and not result.success then
                    logger.error("menu", "ImportResolveDatabase returned error: " .. tostring(result.error_message or "unknown"))
                else
                    logger.info("menu", "Resolve database imported successfully")
                end
            end

        elseif command_name == "ShowKeyboardCustomization" then
            logger.info("menu", "Opening keyboard customization dialog")
            local ok, err = pcall(function()
                require("ui.keyboard_customization_dialog").show()
            end)
            if not ok then
                logger.error("menu", "Failed to open keyboard dialog: " .. tostring(err))
            end

        elseif command_name == "Split" then
            -- Map Split menu item to BatchCommand of SplitClip operations
            if not timeline_panel then
                logger.warn("menu", "Split: timeline panel not available")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local playhead_value = timeline_state.get_playhead_position()
            local selected_clips = timeline_state.get_selected_clips()

            local target_clips
            if selected_clips and #selected_clips > 0 then
                target_clips = timeline_state.get_clips_at_time(playhead_value, selected_clips)
            else
                target_clips = timeline_state.get_clips_at_time(playhead_value)
            end

            if #target_clips == 0 then
                if selected_clips and #selected_clips > 0 then
                    logger.warn("menu", "Split: playhead does not intersect selected clips")
                else
                    logger.warn("menu", "Split: no clips under playhead")
                end
                return
            end

            local json = require("dkjson")
            local Command = require("command")
            local specs = {}

            local rate = timeline_state.get_sequence_frame_rate and timeline_state.get_sequence_frame_rate()
            if not rate or not rate.fps_numerator or not rate.fps_denominator then
                error("Split: Active sequence frame rate unavailable", 2)
            end

            for _, clip in ipairs(target_clips) do
                local start_value = Rational.hydrate(clip.timeline_start or clip.start_value, rate.fps_numerator, rate.fps_denominator)
                local duration_value = Rational.hydrate(clip.duration or clip.duration_value, rate.fps_numerator, rate.fps_denominator)
                local playhead_rt = Rational.hydrate(playhead_value, rate.fps_numerator, rate.fps_denominator)

                if start_value and duration_value and duration_value.frames > 0 and playhead_rt then
                    local end_time = start_value + duration_value
                    if playhead_rt > start_value and playhead_rt < end_time then
                        table.insert(specs, {
                            command_type = "SplitClip",
                            parameters = {
                                clip_id = clip.id,
                                split_time = playhead_rt
                            }
                        })
                    end
                else
                    -- Skip invalid targets to avoid SplitClip errors
                end
            end

            if #specs == 0 then
                logger.warn("menu", "Split: no valid clips to split at current playhead position")
                return
            end

            local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or nil
            assert(project_id and project_id ~= "", "menu_system: Split missing active project_id")
            local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or nil
            assert(active_sequence_id and active_sequence_id ~= "", "menu_system: Split missing active sequence_id")

            local batch_cmd = Command.create("BatchCommand", project_id)
            batch_cmd:set_parameter("sequence_id", active_sequence_id)
            batch_cmd:set_parameter("__snapshot_sequence_ids", {active_sequence_id})
            batch_cmd:set_parameter("commands_json", json.encode(specs))

            local success, result = pcall(function()
                return command_manager.execute(batch_cmd)
            end)
            if not success then
                logger.error("menu", "Split failed: " .. tostring(result))
            elseif result and not result.success then
                logger.error("menu", "Split returned error: " .. tostring(result.error_message or "unknown"))
            else
                logger.info("menu", string.format("Split executed on %d clip(s)", #specs))
            end
        elseif command_name == "Insert" then
            -- Timeline > Insert menu item (same logic as F9)
            assert(timeline_panel, "menu_system: Insert timeline panel not available")
            assert(project_browser and project_browser.insert_selected_to_timeline, "menu_system: Insert project browser not available")
            project_browser.insert_selected_to_timeline("Insert", {advance_playhead = true})

        elseif command_name == "Overwrite" then
            -- Timeline > Overwrite menu item (same logic as F10)
            assert(timeline_panel, "menu_system: Overwrite timeline panel not available")
            assert(project_browser and project_browser.insert_selected_to_timeline, "menu_system: Overwrite project browser not available")
            project_browser.insert_selected_to_timeline("Overwrite", {advance_playhead = true})

        elseif command_name == "TimelineZoomIn" then
            -- Zoom in: decrease viewport duration (show less time)
            if not timeline_panel then
                logger.warn("menu", "ZoomIn: timeline panel not available")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration = current_duration * 0.8  -- Rational arithmetic
            
            -- Clamp to min 1 second (Rational)
            local min_dur = Rational.from_seconds(1.0, new_duration.fps_numerator, new_duration.fps_denominator)
            new_duration = Rational.max(min_dur, new_duration)
            
            if keyboard_shortcuts.clear_zoom_toggle then
                keyboard_shortcuts.clear_zoom_toggle()
            end
            timeline_state.set_viewport_duration(new_duration)
            logger.info("menu", string.format("Zoomed in: %s visible", tostring(new_duration)))

        elseif command_name == "TimelineZoomOut" then
            -- Zoom out: increase viewport duration (show more time)
            if not timeline_panel then
                logger.warn("menu", "ZoomOut: timeline panel not available")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration = current_duration * 1.25  -- Rational arithmetic
            
            if keyboard_shortcuts.clear_zoom_toggle then
                keyboard_shortcuts.clear_zoom_toggle()
            end
            timeline_state.set_viewport_duration(new_duration)
            logger.info("menu", string.format("Zoomed out: %s visible", tostring(new_duration)))

        elseif command_name == "TimelineZoomFit" then
            -- Zoom to fit: show entire timeline
            if not timeline_panel then
                logger.warn("menu", "ZoomFit: timeline panel not available")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local ok = keyboard_shortcuts.toggle_zoom_fit(timeline_state)
            if not ok then
                -- toggle function already printed warning
                return
            end

        elseif command_name == "RenameItem" or command_name == "RenameMedia" then
            local rename_started = false
            if project_browser and project_browser.start_inline_rename then
                -- Ensure project browser has matching selection when timeline clip is focused
                if focus_manager and focus_manager.get_focused_panel then
                    local focused_panel = focus_manager.get_focused_panel()
                    logger.debug("menu", string.format("Rename: focused panel=%s", tostring(focused_panel)))
                    if focused_panel == "timeline" and timeline_panel and timeline_panel.get_state then
                        local state = timeline_panel.get_state()
                        if not state then
                            logger.warn("menu", "Rename: timeline_panel.get_state() returned nil")
                        end
                        if state and state.get_selected_clips then
                            local selected_clips = state.get_selected_clips()
                            logger.debug("menu", string.format("Rename: timeline selected clips=%d", selected_clips and #selected_clips or 0))
                            local target_clip = selected_clips and selected_clips[1] or nil
                            if target_clip then
                                local master_id = target_clip.parent_clip_id or target_clip.id
                                logger.debug("menu", string.format("Rename: targeting master clip %s", tostring(master_id)))
                                if master_id and project_browser.focus_master_clip then
                                    local ok, focus_err = project_browser.focus_master_clip(master_id, {skip_activate = true})
                                    if not ok then
                                        logger.warn("menu", "Rename: focus_master_clip failed - " .. tostring(focus_err))
                                    end
                                    if not ok then
                                        -- keep going; inline rename will still attempt current selection
                                    end
                                end
                            end
                        end
                    end
                end
                rename_started = project_browser.start_inline_rename()
                logger.debug("menu", string.format("Rename: start_inline_rename returned %s", tostring(rename_started)))
            end
            if not rename_started then
                logger.warn("menu", "Rename: no available item to rename")
            end
            return

        elseif command_name == "Cut" then
            local result = command_manager.execute("Cut")
            if result.success then
                logger.info("menu", "Cut executed successfully")
            else
                logger.error("menu", "Cut returned error: " .. tostring(result.error_message or "unknown"))
            end
        elseif command_name == "Copy" then
            local ok, err = clipboard_actions.copy()
            if not ok then
                logger.error("menu", "Copy failed: " .. tostring(err or "unknown error"))
            end
        elseif command_name == "Paste" then
            local ok, err = clipboard_actions.paste()
            if not ok then
                logger.error("menu", "Paste failed: " .. tostring(err or "unknown error"))
            end
        elseif command_name == "Delete" then
            if keyboard_shortcuts.perform_delete_action({shift = false}) then
                return
            end
            logger.debug("menu", "Delete: nothing to delete in current context")
        else
            -- Regular command execution
            local command_params = params
            if command_params == nil then
                command_params = {}
            end
            local success_flag, result_value = pcall(function()
                return command_manager.execute(command_name, command_params)
            end)
            if not success_flag then
                logger.error("menu", string.format("Command '%s' failed: %s", tostring(command_name), tostring(result_value)))
            elseif result_value and not result_value.success then
                logger.error("menu", string.format("Command '%s' returned error: %s", tostring(command_name), tostring(result_value.error_message or "unknown")))
            else
                logger.debug("menu", string.format("Command '%s' executed successfully", tostring(command_name)))
            end
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
            register_menu_shortcut(current_path, child.attrs)

            local item_name = child.attrs.name
            local command_name = child.attrs.command
            local shortcut = convert_shortcut(child.attrs.shortcut)
            local checkable = child.attrs.checkable == "true"
            local params = {}
            if child.attrs.params ~= nil then
                params = parse_params(child.attrs.params)
            end

            local action = qt.CREATE_MENU_ACTION(menu, item_name, shortcut, checkable)

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

    if not defaults_initialized then
        keyboard_shortcut_registry.reset_to_defaults()
        defaults_initialized = true
    end

    logger.info("menu", string.format("Loaded %d menus from %s", #menus_elem.children, tostring(xml_path)))
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
