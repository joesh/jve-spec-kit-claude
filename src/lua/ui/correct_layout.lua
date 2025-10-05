-- Correct layout: 3 panels across top, timeline across bottom

-- Enable strict nil error handling - calling nil will raise an error with proper stack trace
debug.setmetatable(nil, {
  __call = function()
    error("attempt to call nil value", 2)
  end
})

-- Disable print buffering for immediate output
io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

print("🎬 Creating correct layout...")

-- Initialize database connection
print("💾 Initializing database...")
local db_module = require("core.database")

-- Determine database path - single .jvp file is the project file
local home = os.getenv("HOME")
local projects_dir = home .. "/Documents/JVE Projects"
local db_path = projects_dir .. "/Untitled Project.jvp"
print("💾 Project file: " .. db_path)

-- Create projects directory if it doesn't exist
os.execute('mkdir -p "' .. projects_dir .. '"')

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
    local command_manager = require("core.command_manager")
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
                INSERT INTO sequences (id, project_id, name, frame_rate, width, height, timecode_start)
                VALUES ('default_sequence', 'default_project', 'Sequence 1', 30.0, 1920, 1080, 0)
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

            -- Insert test clips
            local insert_clip1 = db_conn:prepare([[
                INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
                VALUES ('clip1', 'video1', 'media1', 0, 5000, 0, 5000, 1)
            ]])
            if insert_clip1 then insert_clip1:exec() end

            local insert_clip2 = db_conn:prepare([[
                INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
                VALUES ('clip2', 'video1', 'media1', 6000, 4000, 0, 4000, 1)
            ]])
            if insert_clip2 then insert_clip2:exec() end

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

-- 1. Project Browser (left)
local project_browser_mod = require("ui.project_browser")
local project_browser = project_browser_mod.create()

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
else
    print("ERROR: Inspector mount failed: " .. tostring(mount_result))
end

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

-- Show window
qt_constants.DISPLAY.SHOW(main_window)
print("✅ Correct layout created: 3 panels top, timeline bottom")

return main_window