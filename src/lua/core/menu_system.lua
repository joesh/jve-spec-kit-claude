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
local command_manager = nil
local main_window = nil
local project_browser = nil
local timeline_panel = nil

local registered_shortcut_commands = {}
local defaults_initialized = false

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

        elseif command_name == "ImportFCP7XML" then
            print("📂 Opening file picker for ImportFCP7XML...")
            local file_path = qt_constants.FILE_DIALOG.OPEN_FILE(
                main_window,
                "Import Final Cut Pro 7 XML",
                "Final Cut Pro XML (*.xml);;All Files (*)"
            )

            if file_path then
                print(string.format("📥 Importing FCP7 XML: %s", file_path))
                local Command = require("command")
                local cmd = Command.create("ImportFCP7XML", "default_project")
                cmd:set_parameter("xml_path", file_path)
                cmd:set_parameter("project_id", "default_project")

                local success, result = pcall(function()
                    return command_manager.execute(cmd)
                end)

                if not success then
                    print(string.format("❌ Import failed: %s", tostring(result)))
                elseif result and not result.success then
                    print(string.format("⚠️  Import error: %s", result.error_message or "unknown"))
                else
                    print("✅ FCP7 XML imported successfully!")
                    if project_browser and project_browser.refresh then
                        project_browser.refresh()
                    end
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

        elseif command_name == "ShowKeyboardCustomization" then
            print("🎹 Opening keyboard customization dialog")
            local ok, err = pcall(function()
                require("ui.keyboard_customization_dialog").show()
            end)
            if not ok then
                print(string.format("❌ Failed to open keyboard dialog: %s", tostring(err)))
            end

        elseif command_name == "Split" then
            -- Map Split menu item to BatchCommand of SplitClip operations
            print("✂️  Calling SplitClip command (mapped from Split)")

            if not timeline_panel then
                print("❌ Split: Timeline panel not available")
                return
            end

            local timeline_state = timeline_panel.get_state()
            local playhead_time = timeline_state.get_playhead_time()
            local selected_clips = timeline_state.get_selected_clips()

            local target_clips
            if selected_clips and #selected_clips > 0 then
                target_clips = timeline_state.get_clips_at_time(playhead_time, selected_clips)
            else
                target_clips = timeline_state.get_clips_at_time(playhead_time)
            end

            if #target_clips == 0 then
                if selected_clips and #selected_clips > 0 then
                    print("⚠️  Split: Playhead does not intersect selected clips")
                else
                    print("⚠️  Split: No clips under playhead")
                end
                return
            end

            local json = require("dkjson")
            local Command = require("command")
            local specs = {}

            for _, clip in ipairs(target_clips) do
                local start_time = clip.start_time
                local end_time = clip.start_time + clip.duration
                if playhead_time <= start_time or playhead_time >= end_time then
                    -- Skip invalid targets to avoid SplitClip errors
                else
                    table.insert(specs, {
                        command_type = "SplitClip",
                        parameters = {
                            clip_id = clip.id,
                            split_time = playhead_time
                        }
                    })
                end
            end

            if #specs == 0 then
                print("⚠️  Split: No valid clips to split at current playhead position")
                return
            end

            local batch_cmd = Command.create("BatchCommand", "default_project")
            batch_cmd:set_parameter("commands_json", json.encode(specs))

            local success, result = pcall(function()
                return command_manager.execute(batch_cmd)
            end)
            if not success then
                print(string.format("❌ Split failed: %s", tostring(result)))
            elseif result and not result.success then
                print(string.format("⚠️  Split returned error: %s", result.error_message or "unknown"))
            else
                print(string.format("✅ Split executed on %d clip(s)", #specs))
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

            local selected_clip = project_browser.get_selected_media()
            if not selected_clip then
                print("❌ INSERT: No media selected in project browser")
                return
            end

            local media_id = selected_clip.media_id or (selected_clip.media and selected_clip.media.id)
            if not media_id then
                print("❌ INSERT: Selected clip missing media reference")
                return
            end

            local clip_duration = selected_clip.duration or (selected_clip.media and selected_clip.media.duration) or 0

            local timeline_state = timeline_panel.get_state()
            local playhead_time = timeline_state.get_playhead_time()

            local Command = require("command")
            local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or "default_project"
            local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or "default_sequence"
            local track_id = timeline_state.get_default_video_track_id and timeline_state.get_default_video_track_id() or nil
            if not track_id or track_id == "" then
                print("❌ INSERT: Active sequence has no video tracks")
                return
            end

            local cmd = Command.create("Insert", project_id)
            cmd:set_parameter("master_clip_id", selected_clip.clip_id)
            cmd:set_parameter("media_id", media_id)
            cmd:set_parameter("sequence_id", sequence_id)
            cmd:set_parameter("track_id", track_id)
            cmd:set_parameter("insert_time", playhead_time)
            cmd:set_parameter("duration", clip_duration)
            cmd:set_parameter("source_in", 0)
            cmd:set_parameter("source_out", clip_duration)
            cmd:set_parameter("project_id", project_id)
            cmd:set_parameter("advance_playhead", true)

            local success, result = pcall(function()
                return command_manager.execute(cmd)
            end)
            if success and result and result.success then
                print(string.format("✅ INSERT: Added %s at %dms, rippled subsequent clips", selected_clip.name or media_id, playhead_time))
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

            local selected_clip = project_browser.get_selected_media()
            if not selected_clip then
                print("❌ OVERWRITE: No media selected in project browser")
                return
            end

            local media_id = selected_clip.media_id or (selected_clip.media and selected_clip.media.id)
            if not media_id then
                print("❌ OVERWRITE: Selected clip missing media reference")
                return
            end

            local clip_duration = selected_clip.duration or (selected_clip.media and selected_clip.media.duration) or 0

            local timeline_state = timeline_panel.get_state()
            local playhead_time = timeline_state.get_playhead_time()

            local Command = require("command")
            local project_id = timeline_state.get_project_id and timeline_state.get_project_id() or "default_project"
            local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or "default_sequence"
            local track_id = timeline_state.get_default_video_track_id and timeline_state.get_default_video_track_id() or nil
            if not track_id or track_id == "" then
                print("❌ OVERWRITE: Active sequence has no video tracks")
                return
            end

            local cmd = Command.create("Overwrite", project_id)
            cmd:set_parameter("master_clip_id", selected_clip.clip_id)
            cmd:set_parameter("media_id", media_id)
            cmd:set_parameter("sequence_id", sequence_id)
            cmd:set_parameter("track_id", track_id)
            cmd:set_parameter("overwrite_time", playhead_time)
            cmd:set_parameter("duration", clip_duration)
            cmd:set_parameter("source_in", 0)
            cmd:set_parameter("source_out", clip_duration)
            cmd:set_parameter("project_id", project_id)
            cmd:set_parameter("advance_playhead", true)

            local success, result = pcall(function()
                return command_manager.execute(cmd)
            end)
            if success and result and result.success then
                print(string.format("✅ OVERWRITE: Added %s at %dms, trimmed overlapping clips", selected_clip.name or media_id, playhead_time))
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

        elseif command_name == "Cut" then
            local result = command_manager.execute("Cut")
            if result.success then
                print("✂️  Cut executed successfully")
            else
                print(string.format("⚠️  Cut returned error: %s", result.error_message or "unknown"))
            end
        elseif command_name == "Copy" or command_name == "Paste" then
            print(string.format("⚠️  Command '%s' not implemented yet", command_name))
            print("   TODO: Implement clipboard operations")
        elseif command_name == "Delete" then
            print("🗑️  Delete command - checking selection...")
            print("⚠️  Delete command not fully wired to menu yet")
            print("   For now, use Delete key which calls BatchCommand for selected clips")
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
                print(string.format("❌ Command '%s' failed: %s", command_name, tostring(result_value)))
            elseif result_value and not result_value.success then
                print(string.format("⚠️  Command '%s' returned error: %s", command_name, result_value.error_message or "unknown"))
            else
                print(string.format("✅ Command '%s' executed successfully", command_name))
            end
        end
    end
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
