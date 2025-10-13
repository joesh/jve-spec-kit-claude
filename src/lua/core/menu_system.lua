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
local command_manager = nil
local main_window = nil
local project_browser = nil
local timeline_panel = nil

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
    SET_ACTION_CHECKED = qt_constants.MENU.SET_ACTION_CHECKED
}

--- Initialize menu system
-- @param window userdata: QMainWindow instance
-- @param cmd_mgr table: Command manager instance
-- @param proj_browser table: Project browser instance (optional)
function M.init(window, cmd_mgr, proj_browser)
    main_window = window
    command_manager = cmd_mgr
    project_browser = proj_browser
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

--- Create menu action callback
-- @param command_name string: Command to execute
-- @param params table: Command parameters
-- @return function: Callback function
local function create_action_callback(command_name, params)
    return function()
        if not command_manager then
            print("ERROR: Menu system not initialized with command manager")
            return
        end

        print(string.format("🔘 Menu clicked: '%s'", command_name))

        -- Handle special commands that aren't normal execute() calls
        if command_name == "Undo" then
            print("⏪ Calling command_manager.undo()")
            command_manager.undo()
        elseif command_name == "Redo" then
            print("⏩ Calling command_manager.redo()")
            command_manager.redo()
        elseif command_name == "Quit" then
            print("👋 Quitting application")
            os.exit(0)
        elseif command_name == "ImportMedia" then
            print("📂 Opening file picker for ImportMedia...")
            local file_paths = qt_constants.FILE_DIALOG.OPEN_FILES(
                main_window,
                "Import Media Files",
                "Media Files (*.mp4 *.mov *.m4v *.avi *.mkv *.mxf *.wav *.aiff *.mp3);;All Files (*)"
            )

            if file_paths then
                print(string.format("📥 Dialog returned: %s (type: %s)", tostring(file_paths), type(file_paths)))
                if type(file_paths) == "table" then
                    print(string.format("📥 Importing %d media file(s)...", #file_paths))
                    for i, file_path in ipairs(file_paths) do
                        print(string.format("  [%d] Path: '%s' (length: %d)", i, file_path, #file_path))
                        local Command = require("command")
                        local cmd = Command.create("ImportMedia", "default_project")
                        cmd:set_parameter("file_path", file_path)
                        cmd:set_parameter("project_id", "default_project")

                        local success, result = pcall(function()
                            return command_manager.execute(cmd)
                        end)
                        if success then
                            if result and result.success then
                                print(string.format("✅ Imported: %s", file_path))
                            else
                                print(string.format("❌ Command returned error: %s", result and result.error_message or "unknown"))
                                print(string.format("   Result: %s", require("dkjson").encode(result or {})))
                            end
                        else
                            print(string.format("❌ Exception during import: %s", tostring(result)))
                        end
                    end

                    -- Refresh project browser to show newly imported media
                    print(string.format("DEBUG: project_browser = %s", tostring(project_browser)))
                    if project_browser then
                        print(string.format("DEBUG: project_browser.refresh = %s", tostring(project_browser.refresh)))
                        if project_browser.refresh then
                            print("🔄 Refreshing project browser...")
                            project_browser.refresh()
                        else
                            print("⚠️  project_browser.refresh is nil")
                        end
                    else
                        print("⚠️  project_browser is nil - menu system not initialized with project browser")
                    end
                else
                    print("⚠️  File dialog returned non-table value")
                end
            else
                print("⏹️  Import cancelled")
            end

        elseif command_name == "ImportResolveProject" then
            print("📂 Opening file picker for ImportResolveProject...")
            local file_path = qt_constants.FILE_DIALOG.OPEN_FILE(
                main_window,
                "Import Resolve Project (.drp)",
                "Resolve Project Files (*.drp);;All Files (*)"
            )

            if file_path then
                print(string.format("📥 Importing Resolve project: %s", file_path))
                local Command = require("command")
                local cmd = Command.create("ImportResolveProject", "default_project")
                cmd:set_parameter("drp_path", file_path)

                local success, result = pcall(function()
                    return command_manager.execute(cmd)
                end)
                if not success then
                    print(string.format("❌ Import failed: %s", tostring(result)))
                elseif result and not result.success then
                    print(string.format("⚠️  Import error: %s", result.error_message or "unknown"))
                else
                    print("✅ Resolve project imported successfully!")
                end
            else
                print("⏹️  Import cancelled")
            end

        elseif command_name == "ImportResolveDatabase" then
            print("📂 Opening file picker for ImportResolveDatabase...")
            local file_path = qt_constants.FILE_DIALOG.OPEN_FILE(
                main_window,
                "Import Resolve Database",
                "Database Files (*.db *.sqlite *.resolve);;All Files (*)",
                os.getenv("HOME") .. "/Movies/DaVinci Resolve"
            )

            if file_path then
                print(string.format("📥 Importing Resolve database: %s", file_path))
                local Command = require("command")
                local cmd = Command.create("ImportResolveDatabase", "default_project")
                cmd:set_parameter("db_path", file_path)

                local success, result = pcall(function()
                    return command_manager.execute(cmd)
                end)
                if not success then
                    print(string.format("❌ Import failed: %s", tostring(result)))
                elseif result and not result.success then
                    print(string.format("⚠️  Import error: %s", result.error_message or "unknown"))
                else
                    print("✅ Resolve database imported successfully!")
                end
            else
                print("⏹️  Import cancelled")
            end
        elseif command_name == "Split" then
            -- Map Split menu item to SplitClip command
            print("✂️  Calling SplitClip command (mapped from Split)")

            if not timeline_panel then
                print("❌ Split: Timeline panel not available")
                return
            end

            -- Get selected clip and playhead position from timeline
            local timeline_state = timeline_panel.get_state()
            local selected_clips = timeline_state.get_selected_clips()

            if #selected_clips == 0 then
                print("⚠️  Split: No clip selected")
                return
            end

            if #selected_clips > 1 then
                print("⚠️  Split: Cannot split multiple clips at once")
                return
            end

            local clip_id = selected_clips[1].id
            local split_time = timeline_state.get_playhead_time()

            local Command = require("command")
            local cmd = Command.create("SplitClip", "default_project")
            cmd:set_parameter("clip_id", clip_id)
            cmd:set_parameter("split_time", split_time)

            local success, result = pcall(function()
                return command_manager.execute(cmd)
            end)
            if not success then
                print(string.format("❌ SplitClip failed: %s", tostring(result)))
            elseif result and not result.success then
                print(string.format("⚠️  SplitClip returned error: %s", result.error_message or "unknown"))
            else
                print("✅ SplitClip executed successfully")
            end
        elseif command_name == "Insert" then
            -- Timeline > Insert menu item (same logic as F9)
            print("📥 Insert command from menu")

            if not timeline_panel then
                print("❌ INSERT: Timeline panel not available")
                return
            end

            -- Get selected media from project browser
            if not project_browser or not project_browser.get_selected_media then
                print("❌ INSERT: Project browser not available")
                return
            end

            local selected_media = project_browser.get_selected_media()
            if not selected_media then
                print("❌ INSERT: No media selected in project browser")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local playhead_time = timeline_state.get_playhead_time()

            local Command = require("command")
            local cmd = Command.create("Insert", "default_project")
            cmd:set_parameter("media_id", selected_media.id)
            cmd:set_parameter("track_id", "video1")
            cmd:set_parameter("insert_time", playhead_time)
            cmd:set_parameter("duration", selected_media.duration)
            cmd:set_parameter("source_in", 0)
            cmd:set_parameter("source_out", selected_media.duration)
            cmd:set_parameter("advance_playhead", true)

            local success, result = pcall(function()
                return command_manager.execute(cmd)
            end)
            if success and result and result.success then
                print(string.format("✅ INSERT: Added %s at %dms, rippled subsequent clips", selected_media.name, playhead_time))
            else
                print(string.format("❌ INSERT failed: %s", result and result.error_message or "unknown error"))
            end

        elseif command_name == "Overwrite" then
            -- Timeline > Overwrite menu item (same logic as F10)
            print("📥 Overwrite command from menu")

            if not timeline_panel then
                print("❌ OVERWRITE: Timeline panel not available")
                return
            end

            -- Get selected media from project browser
            if not project_browser or not project_browser.get_selected_media then
                print("❌ OVERWRITE: Project browser not available")
                return
            end

            local selected_media = project_browser.get_selected_media()
            if not selected_media then
                print("❌ OVERWRITE: No media selected in project browser")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local playhead_time = timeline_state.get_playhead_time()

            local Command = require("command")
            local cmd = Command.create("Overwrite", "default_project")
            cmd:set_parameter("media_id", selected_media.id)
            cmd:set_parameter("track_id", "video1")
            cmd:set_parameter("overwrite_time", playhead_time)
            cmd:set_parameter("duration", selected_media.duration)
            cmd:set_parameter("source_in", 0)
            cmd:set_parameter("source_out", selected_media.duration)
            cmd:set_parameter("advance_playhead", true)

            local success, result = pcall(function()
                return command_manager.execute(cmd)
            end)
            if success and result and result.success then
                print(string.format("✅ OVERWRITE: Added %s at %dms, trimmed overlapping clips", selected_media.name, playhead_time))
            else
                print(string.format("❌ OVERWRITE failed: %s", result and result.error_message or "unknown error"))
            end

        elseif command_name == "TimelineZoomIn" then
            -- Zoom in: decrease viewport duration (show less time)
            if not timeline_panel then
                print("❌ ZOOM: Timeline panel not available")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration = math.max(1000, current_duration * 0.8)  -- Zoom in 20%, min 1 second
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("🔍 Zoomed in: %.2fs visible", new_duration / 1000))

        elseif command_name == "TimelineZoomOut" then
            -- Zoom out: increase viewport duration (show more time)
            if not timeline_panel then
                print("❌ ZOOM: Timeline panel not available")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local current_duration = timeline_state.get_viewport_duration()
            local new_duration = current_duration * 1.25  -- Zoom out 25%
            timeline_state.set_viewport_duration(new_duration)
            print(string.format("🔍 Zoomed out: %.2fs visible", new_duration / 1000))

        elseif command_name == "TimelineZoomFit" then
            -- Zoom to fit: show entire timeline
            if not timeline_panel then
                print("❌ ZOOM: Timeline panel not available")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local clips = timeline_state.get_clips()

            -- Find rightmost clip edge
            local max_time = 0
            for _, clip in ipairs(clips) do
                local clip_end = clip.start_time + clip.duration
                if clip_end > max_time then
                    max_time = clip_end
                end
            end

            if max_time > 0 then
                -- Add 10% padding
                local new_duration = max_time * 1.1
                timeline_state.set_viewport_duration(new_duration)
                timeline_state.set_viewport_start_time(0)
                print(string.format("🔍 Zoomed to fit: %.2fs visible", new_duration / 1000))
            else
                print("⚠️  No clips to fit")
            end

        elseif command_name == "Cut" or command_name == "Copy" or command_name == "Paste" then
            print(string.format("⚠️  Command '%s' not implemented yet", command_name))
            print("   TODO: Implement clipboard operations")
        elseif command_name == "Delete" then
            print("🗑️  Delete command - checking selection...")
            print("⚠️  Delete command not fully wired to menu yet")
            print("   For now, use Delete key which calls BatchCommand for selected clips")
        else
            -- Regular command execution
            local success, result = pcall(function()
                return command_manager.execute(command_name, params or {})
            end)

            if not success then
                print(string.format("❌ Command '%s' failed: %s", command_name, tostring(result)))
            elseif result and not result.success then
                print(string.format("⚠️  Command '%s' returned error: %s", command_name, result.error_message or "unknown"))
            else
                print(string.format("✅ Command '%s' executed successfully", command_name))
            end
        end
    end
end

--- Build QMenu from XML element (recursive)
-- @param menu_elem table: XML <menu> element
-- @param parent_menu userdata: Qt QMenu or QMenuBar parent
local function build_menu(menu_elem, parent_menu)
    local menu_name = menu_elem.attrs.name or "Untitled"

    -- Create QMenu
    local menu = qt.CREATE_MENU(parent_menu, menu_name)

    -- Process children
    for _, child in ipairs(menu_elem.children) do
        if child.tag == "item" then
            -- Menu item -> QAction
            local item_name = child.attrs.name or "Untitled"
            local command_name = child.attrs.command
            local shortcut = convert_shortcut(child.attrs.shortcut or "")
            local checkable = child.attrs.checkable == "true"
            local params = parse_params(child.attrs.params or "")

            local action = qt.CREATE_MENU_ACTION(menu, item_name, shortcut, checkable)

            if command_name then
                qt.CONNECT_MENU_ACTION(action, create_action_callback(command_name, params))
            end

        elseif child.tag == "separator" then
            -- Separator
            qt.ADD_MENU_SEPARATOR(menu)

        elseif child.tag == "menu" then
            -- Submenu (recursive)
            local submenu = build_menu(child, menu)
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

    -- Parse XML
    local root, err = parse_xml_file(xml_path)
    if not root then
        return false, err
    end

    local menus_elem = find_element(root, "menus")
    if not menus_elem then
        return false, "No <menus> root element found"
    end

    -- Create menu bar
    local menu_bar = qt.GET_MENU_BAR(main_window)

    -- Build all top-level menus
    for _, child in ipairs(menus_elem.children) do
        if child.tag == "menu" then
            local menu = build_menu(child, menu_bar)
            qt.ADD_MENU_TO_BAR(menu_bar, menu)
        end
    end

    print(string.format("Menu system: Loaded %d menus from %s", #menus_elem.children, xml_path))
    return true
end

--- Update menu item enabled state
-- @param command_name string: Command name
-- @param enabled boolean: Whether item should be enabled
function M.set_item_enabled(command_name, enabled)
    -- TODO: Track action objects by command name for state updates
end

--- Update menu item checked state
-- @param command_name string: Command name
-- @param checked boolean: Whether item should be checked
function M.set_item_checked(command_name, checked)
    -- TODO: Track action objects by command name for state updates
end

return M
