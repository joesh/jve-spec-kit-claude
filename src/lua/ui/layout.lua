-- Application layout: 3 panels across top, timeline across bottom

-- Add luarocks path for C modules (like lxp.so)
package.cpath = package.cpath .. ';' .. os.getenv('HOME') .. '/.luarocks/lib/lua/5.1/?.so'
package.path = package.path .. ';' .. os.getenv('HOME') .. '/.luarocks/share/lua/5.1/?.lua'
package.path = package.path .. ';' .. os.getenv('HOME') .. '/.luarocks/share/lua/5.1/?/init.lua'

-- Enable strict nil error handling - calling nil will raise an error with proper stack trace
debug.setmetatable(nil, {
  __call = function()
    error("attempt to call nil value", 2)
  end
})

-- Disable print buffering for immediate output
io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

print("🎬 Creating layout...")

-- Initialize database connection
print("💾 Initializing database...")
local db_module = require("core.database")

-- Determine database path - check for test environment variable first
local db_path = os.getenv("JVE_PROJECT_PATH") or os.getenv("JVE_TEST_DATABASE")
if db_path then
    print("💾 Using test database: " .. db_path)
else
    -- Normal production path - single .jvp file is the project file
    local home = os.getenv("HOME")
    local projects_dir = home .. "/Documents/JVE Projects"
    db_path = projects_dir .. "/Untitled Project.jvp"
    print("💾 Project file: " .. db_path)

    -- Create projects directory if it doesn't exist
    os.execute('mkdir -p "' .. projects_dir .. '"')
end

-- Initialize command_manager module reference (will be initialized later)
local command_manager = require("core.command_manager")

-- Open database connection
local db_success = db_module.set_path(db_path)
if not db_success then
    print("❌ Failed to open database connection")
else
    print("✅ Database connection established")

    -- Initialize database schema if needed
    local db_conn = db_module.get_connection()
    if db_conn then
        local schema_check, err = db_conn:prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='projects'")
        if not schema_check then
            print("❌ Failed to prepare schema check query: " .. tostring(err))
        else
            local has_schema = false
            if schema_check:exec() then
                has_schema = schema_check:next()
            end

            if not has_schema then
                print("💾 Creating database schema...")
                -- Read and execute schema.sql
                local schema_file = io.open("src/core/persistence/schema.sql", "r")
                if schema_file then
                    local schema_sql = schema_file:read("*all")
                    schema_file:close()

                    -- Execute schema as a single batch using exec (not prepare)
                    -- Note: LuaJIT FFI doesn't have exec(), so we need to use a different approach
                    -- For now, just execute the critical CREATE TABLE statements
                    local create_statements = {}
                    for statement in schema_sql:gmatch("CREATE TABLE.-%;") do
                        table.insert(create_statements, statement)
                    end

                    for _, statement in ipairs(create_statements) do
                        local stmt, stmt_err = db_conn:prepare(statement)
                        if stmt then
                            local success = stmt:exec()
                            if not success then
                                print("❌ Failed to execute statement: " .. tostring(stmt:last_error()))
                            end
                        else
                            print("❌ Failed to prepare CREATE TABLE: " .. tostring(stmt_err))
                        end
                    end
                    print("✅ Database schema created")
                else
                    print("❌ Failed to open schema.sql")
                end
            end
        end
    else
        print("❌ Database connection is nil")
    end

    -- Initialize CommandManager with database
    command_manager.init(db_module.get_connection())
    print("✅ CommandManager initialized with database")

    -- Create test project data if database is empty
    local project_check = db_conn:prepare("SELECT COUNT(*) FROM projects")
    if project_check and project_check:exec() and project_check:next() then
        local project_count = project_check:value(0)
        if project_count == 0 then
            print("💾 Creating test project data...")
            -- Insert test project
            local insert_project = db_conn:prepare([[
                INSERT INTO projects (id, name, created_at, modified_at, settings)
                VALUES ('default_project', 'Untitled Project', strftime('%s', 'now'), strftime('%s', 'now'), '{}')
            ]])
            if insert_project then insert_project:exec() end

            -- Insert test sequence
            local insert_sequence = db_conn:prepare([[
                INSERT INTO sequences (id, project_id, name, frame_rate, width, height, timecode_start, playhead_time, selected_clip_ids, selected_edge_infos)
                VALUES ('default_sequence', 'default_project', 'Sequence 1', 30.0, 1920, 1080, 0, 0, '[]', '[]')
            ]])
            if insert_sequence then insert_sequence:exec() end

            -- Insert test tracks
            -- Video tracks
            local insert_video1 = db_conn:prepare([[
                INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
                VALUES ('video1', 'default_sequence', 'V1', 'VIDEO', 1, 1)
            ]])
            if insert_video1 then insert_video1:exec() end

            local insert_video2 = db_conn:prepare([[
                INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
                VALUES ('video2', 'default_sequence', 'V2', 'VIDEO', 2, 1)
            ]])
            if insert_video2 then insert_video2:exec() end

            local insert_video3 = db_conn:prepare([[
                INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
                VALUES ('video3', 'default_sequence', 'V3', 'VIDEO', 3, 1)
            ]])
            if insert_video3 then insert_video3:exec() end

            -- Audio tracks
            local insert_audio1 = db_conn:prepare([[
                INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
                VALUES ('audio1', 'default_sequence', 'A1', 'AUDIO', 1, 1)
            ]])
            if insert_audio1 then insert_audio1:exec() end

            local insert_audio2 = db_conn:prepare([[
                INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
                VALUES ('audio2', 'default_sequence', 'A2', 'AUDIO', 2, 1)
            ]])
            if insert_audio2 then insert_audio2:exec() end

            local insert_audio3 = db_conn:prepare([[
                INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
                VALUES ('audio3', 'default_sequence', 'A3', 'AUDIO', 3, 1)
            ]])
            if insert_audio3 then insert_audio3:exec() end

            -- Insert test media
            local insert_media = db_conn:prepare([[
                INSERT INTO media (id, file_path, file_name, duration, frame_rate, metadata)
                VALUES ('media1', '/path/to/test.mp4', 'test.mp4', 10000, 30.0, '{}')
            ]])
            if insert_media then insert_media:exec() end

            -- Note: Test clips are now added via commands after timeline initialization
            -- This ensures they're part of the event stream for proper undo/redo

            print("✅ Test project data created")
        end
    end
end

-- Create main window
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_TITLE(main_window, "JVE Editor - Correct Layout")
qt_constants.PROPERTIES.SET_SIZE(main_window, 1600, 900)

-- Main vertical splitter (Top row | Timeline)
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

-- Top row: Horizontal splitter (Project Browser | Viewer | Inspector)
local top_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

-- 1. Project Browser (left) - create EARLY so menu system can reference it
local project_browser_mod = require("ui.project_browser")
local project_browser = project_browser_mod.create()

-- Initialize menu system AFTER project browser exists
print("📋 Initializing menu system...")
local menu_system = require("core.menu_system")
menu_system.init(main_window, command_manager, project_browser_mod)

-- Load menus from XML
local menu_success, menu_error = menu_system.load_from_file("menus.xml")
if menu_success then
    print("✅ Menu system loaded successfully")
else
    print("❌ Failed to load menu system: " .. tostring(menu_error))
end

-- 2. Src/Timeline Viewer (center)
local viewer_panel = qt_constants.WIDGET.CREATE()
local viewer_layout = qt_constants.LAYOUT.CREATE_VBOX()
local viewer_title = qt_constants.WIDGET.CREATE_LABEL("Src/Timeline Viewer")
qt_constants.PROPERTIES.SET_STYLE(viewer_title, "background: #3a3a3a; color: white; padding: 4px; font-size: 12px;")
qt_constants.LAYOUT.ADD_WIDGET(viewer_layout, viewer_title)

local viewer_content = qt_constants.WIDGET.CREATE_LABEL("Video Preview")
qt_constants.PROPERTIES.SET_STYLE(viewer_content, "background: black; color: #666; padding: 40px; text-align: center;")
qt_constants.LAYOUT.ADD_WIDGET(viewer_layout, viewer_content)
qt_constants.LAYOUT.SET_ON_WIDGET(viewer_panel, viewer_layout)

-- 3. Inspector (right) - Create container for Lua inspector
local inspector_panel = qt_constants.WIDGET.CREATE_INSPECTOR()

-- 4. Timeline panel (create early, before inspector blocks execution)
local timeline_panel_mod = require("ui.timeline.timeline_panel")
local timeline_panel = timeline_panel_mod.create()

-- 5. Initialize keyboard shortcuts with the SAME timeline_state instance that timeline_panel uses
-- Note: Use F9 and F10 to add test clips via commands
local keyboard_shortcuts = require("core.keyboard_shortcuts")
local timeline_state_from_panel = timeline_panel_mod.get_state()
print(string.format("DEBUG: timeline_state from panel = %s", tostring(timeline_state_from_panel)))
keyboard_shortcuts.init(timeline_state_from_panel, command_manager, project_browser_mod, timeline_panel_mod)

-- 6. Initialize focus manager for visual panel indicators
local focus_manager = require("ui.focus_manager")

-- Initialize the Lua inspector content following working reference pattern
local view = require("ui.inspector.view")

-- First mount the view on the container
local mount_result = view.mount(inspector_panel)
if mount_result and mount_result.success then
    -- Then create the schema-driven content
    local inspector_success, inspector_result = pcall(view.create_schema_driven_inspector)

    if not inspector_success then
        print("ERROR: Inspector creation failed: " .. tostring(inspector_result))
    end

    -- Wire up timeline to inspector
    timeline_panel_mod.set_inspector(view)

    -- Wire up timeline to project browser for media insertion
    timeline_panel_mod.set_project_browser(project_browser_mod)

    -- Wire up project browser to timeline for insert button
    project_browser_mod.set_timeline_panel(timeline_panel_mod)

    -- Wire up menu system to timeline for Split command
    menu_system.set_timeline_panel(timeline_panel_mod)
else
    print("ERROR: Inspector mount failed: " .. tostring(mount_result))
end

-- Register all panels with focus manager for visual indicators
focus_manager.register_panel("project_browser", project_browser, nil, "Project Browser")
focus_manager.register_panel("viewer", viewer_panel, viewer_title, "Viewer")
focus_manager.register_panel("inspector", inspector_panel, nil, "Inspector")
focus_manager.register_panel("timeline", timeline_panel, nil, "Timeline")

-- Initialize all panels to unfocused state
focus_manager.initialize_all_panels()

-- Add three panels to top splitter
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, project_browser)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, viewer_panel)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, inspector_panel)

-- Set top splitter proportions (equal thirds)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(top_splitter, {533, 533, 534})

-- Add top row and timeline to main splitter
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, top_splitter)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, timeline_panel)

-- Set main splitter proportions (top: 50%, timeline: 50%)
qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {450, 450})

-- Set as central widget
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)

-- Apply dark theme
qt_constants.PROPERTIES.SET_STYLE(main_window, [[
    QMainWindow { background: #2b2b2b; }
    QWidget { background: #2b2b2b; color: white; }
    QLabel { background: #3a3a3a; color: white; border: 1px solid #555; padding: 8px; }
    QSplitter { background: #2b2b2b; }
    QSplitter::handle { background: #555; width: 2px; height: 2px; }
    QTreeWidget { background: #353535; color: white; border: 1px solid #555; }
    QLineEdit { background: #353535; color: white; border: 1px solid #555; padding: 4px; }
]])

-- Install global keyboard shortcut handler (skip in test mode to avoid crashes)
local is_test_mode = os.getenv("JVE_TEST_DATABASE") ~= nil
if not is_test_mode then
    _G.global_key_handler = function(event)
        return keyboard_shortcuts.handle_key(event)
    end
    qt_set_global_key_handler(main_window, "global_key_handler")
    print("✅ Keyboard shortcuts installed")
else
    print("⚠️  Keyboard shortcuts disabled in test mode")
end

-- Show window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ Correct layout created: 3 panels top, timeline bottom")

-- Debug: Check actual widget sizes after window is shown
local window_w, window_h = qt_constants.PROPERTIES.GET_SIZE(main_window)
local timeline_w, timeline_h = qt_constants.PROPERTIES.GET_SIZE(timeline_panel)
local inspector_w, inspector_h = qt_constants.PROPERTIES.GET_SIZE(inspector_panel)
print(string.format("DEBUG: Main window size: %dx%d", window_w, window_h))
print(string.format("DEBUG: Timeline panel size: %dx%d (panel HAS correct width!)", timeline_w, timeline_h))
print(string.format("DEBUG: Inspector panel size: %dx%d", inspector_w, inspector_h))

return main_window
