-- Add luarocks path for C modules (like lxp.so)
package.cpath = package.cpath .. ';' .. os.getenv('HOME') .. '/.luarocks/lib/lua/5.1/?.so'
package.path = package.path .. ';' .. os.getenv('HOME') .. '/.luarocks/share/lua/5.1/?.lua'
package.path = package.path .. ';' .. os.getenv('HOME') .. '/.luarocks/share/lua/5.1/?/init.lua'

local ui_constants = require("core.ui_constants")
local qt_constants = require("core.qt_constants")
local Project = require("models.project")
local logger = require("core.logger")
local project_open = require("core.project_open")

-- Enable strict nil error handling - calling nil will raise an error with proper stack trace
debug.setmetatable(nil, {
  __call = function()
    error("attempt to call nil value", 2)
  end
})

-- Global error handler for automatic bug capture
local function global_error_handler(err)
    local stack_trace = debug.traceback(tostring(err), 2)
    logger.fatal("layout", "FATAL ERROR: " .. tostring(err))
    logger.fatal("layout", stack_trace)

    -- Capture bug report automatically on errors
    local ok, bug_reporter = pcall(require, "bug_reporter.init")
    if ok and bug_reporter then
        local test_path = bug_reporter.capture_on_error(tostring(err), stack_trace)
        if test_path then
            logger.info("layout", "Bug report auto-captured: " .. tostring(test_path))
            logger.info("layout", "Press F12 to review and submit")
        end
    end

    return tostring(err) .. "\n" .. stack_trace
end

-- Install global error handler
_G.error_handler = global_error_handler

-- Disable print buffering for immediate output
io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

logger.info("layout", "Creating layout...")
local layout_path = debug.getinfo(1, "S").source:sub(2)
local layout_dir = layout_path:match("(.*/)")

-- Initialize database connection
logger.info("layout", "Initializing database...")
local db_module = require("core.database")

-- Determine database path - check for test environment variable first
local db_path = os.getenv("JVE_PROJECT_PATH")
if db_path then
    logger.info("layout", "Using test database: " .. tostring(db_path))
else
    -- Normal production path - single .jvp file is the project file
    local home = os.getenv("HOME")
    local projects_dir = home .. "/Documents/JVE Projects"
    db_path = projects_dir .. "/Untitled Project.jvp"
    logger.info("layout", "Project file: " .. tostring(db_path))

    -- Create projects directory if it doesn't exist
    os.execute('mkdir -p "' .. projects_dir .. '"')
end

local project_display_name = nil
local active_project_id
local active_sequence_id

-- Initialize command_manager module reference (will be initialized later)
local command_manager = require("core.command_manager")

-- Open database connection
local db_success = project_open.open_project_database_or_prompt_cleanup(db_module, qt_constants, db_path)
if not db_success then
    logger.error("layout", "Failed to open database connection; exiting")
    os.exit(1)
else
    logger.debug("layout", "Database connection established")
    local db_conn = db_module.get_connection()
    if not db_conn then
        error("FATAL: Database connection reported as established but is nil")
    end

    -- Initialize database schema if needed before querying any tables
    local schema_check, err = db_conn:prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='projects'")
    if not schema_check then
        error("FATAL: Failed to prepare schema check query: " .. tostring(err))
    end

    local has_schema = false
    if schema_check:exec() then
        has_schema = schema_check:next()
    end
    schema_check:finalize()

    if not has_schema then
        logger.info("layout", "Creating database schema...")
        local schema_path = layout_dir .. "../../core/persistence/schema.sql"
        local schema_file, ferr = io.open(schema_path, "r")
        if not schema_file then
            error("FATAL: Failed to open schema.sql at " .. schema_path .. ": " .. tostring(ferr))
        end
        local schema_sql = schema_file:read("*all")
        schema_file:close()

        local ok, exec_err = db_conn:exec(schema_sql)
        if not ok then
            error("FATAL: Failed to apply schema: " .. tostring(exec_err))
        end
        logger.info("layout", "Database schema created")
    end

    local function ensure_default_data()
        local function table_count(sql)
            local stmt, stmt_err = db_conn:prepare(sql)
            if not stmt then
                error("FATAL: Failed to prepare count query: " .. tostring(stmt_err))
            end
            local value = 0
            if stmt:exec() and stmt:next() then
                value = tonumber(stmt:value(0)) or 0
            end
            stmt:finalize()
            return value
        end

        if table_count("SELECT COUNT(*) FROM projects") == 0 then
            local insert_project = db_conn:prepare([[
                INSERT INTO projects (id, name, created_at, modified_at, settings)
                VALUES ('default_project', 'Untitled Project', strftime('%s', 'now'), strftime('%s', 'now'), '{}')
            ]])
            if not insert_project then
                error("FATAL: Failed to prepare default project insert")
            end
            insert_project:exec()
            insert_project:finalize()
            logger.info("layout", "Inserted default project")
        end

        local sequence_id = nil
        if table_count("SELECT COUNT(*) FROM sequences") == 0 then
            local insert_sequence = db_conn:prepare([[
                INSERT INTO sequences (
                    id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
                    width, height, playhead_frame,
                    selected_clip_ids, selected_edge_infos, selected_gap_infos,
                    view_start_frame, view_duration_frames, created_at, modified_at
                ) VALUES (
                    'default_sequence', 'default_project', 'Sequence 1', 'timeline', 24, 1, 48000,
                    1920, 1080, 0,
                    '[]', '[]', '[]',
                    0, 240, strftime('%s', 'now'), strftime('%s', 'now')
                )
            ]])
            if not insert_sequence then
                error("FATAL: Failed to prepare default sequence insert")
            end
            local ok_seq = insert_sequence:exec()
            insert_sequence:finalize()
            assert(ok_seq ~= false, "FATAL: Failed to insert default sequence")
            sequence_id = "default_sequence"
        else
            local seq_stmt = db_conn:prepare("SELECT id, fps_numerator, fps_denominator, audio_rate FROM sequences LIMIT 1")
            if not seq_stmt then
                error("FATAL: Failed to query existing sequence")
            end
            local ok = seq_stmt:exec() and seq_stmt:next()
            if ok then
                sequence_id = seq_stmt:value(0)
            end
            seq_stmt:finalize()
            assert(sequence_id, "FATAL: Existing sequence missing id")
        end

        -- Ensure tracks exist for the active sequence
        local function insert_track(seq_id, id, name, track_type, track_index)
            local stmt = db_conn:prepare([[
                INSERT INTO tracks (
                    id, sequence_id, name, track_type,
                    track_index, enabled, locked, muted, soloed, volume, pan
                )
                VALUES (?, ?, ?, ?, ?, 1, 0, 0, 0, 1.0, 0.0)
            ]])
            if not stmt then
                error("FATAL: Failed to prepare default track insert")
            end
            stmt:bind_value(1, id)
            stmt:bind_value(2, seq_id)
            stmt:bind_value(3, name)
            stmt:bind_value(4, track_type)
            stmt:bind_value(5, track_index)
            local ok = stmt:exec()
            stmt:finalize()
            assert(ok ~= false, string.format("FATAL: Failed to insert track %s", tostring(id)))
        end

        -- Only seed tracks if none exist for the active sequence
        local track_count_sql = string.format("SELECT COUNT(*) FROM tracks WHERE sequence_id = '%s'", sequence_id)
        if table_count(track_count_sql) == 0 then
            insert_track(sequence_id, "video1", "V1", "VIDEO", 1)
            insert_track(sequence_id, "video2", "V2", "VIDEO", 2)
            insert_track(sequence_id, "video3", "V3", "VIDEO", 3)
            insert_track(sequence_id, "audio1", "A1", "AUDIO", 1)
            insert_track(sequence_id, "audio2", "A2", "AUDIO", 2)
            insert_track(sequence_id, "audio3", "A3", "AUDIO", 3)

            local insert_media = db_conn:prepare([[
                INSERT INTO media (
                    id, project_id, name, file_path,
                    duration_frames, fps_numerator, fps_denominator,
                    width, height, audio_channels, codec,
                    created_at, modified_at, metadata
                )
                VALUES (
                    'media1', 'default_project', 'test.mp4', '/path/to/test.mp4',
                    2400, 24, 1,
                    1920, 1080, 2, 'h264',
                    strftime('%s','now'), strftime('%s','now'), '{}'
                )
            ]])
            if insert_media then
                insert_media:exec()
                insert_media:finalize()
            end

            logger.info("layout", "Inserted default sequence and tracks")
        end

        return sequence_id
    end

    active_sequence_id = ensure_default_data()
    assert(active_sequence_id and active_sequence_id ~= "", "FATAL: Unable to resolve active sequence id after default data init")

    local project_stmt = db_conn:prepare("SELECT project_id FROM sequences WHERE id = ?")
    assert(project_stmt, "FATAL: Failed to prepare active sequence -> project query")
    project_stmt:bind_value(1, active_sequence_id)
    if project_stmt:exec() and project_stmt:next() then
        active_project_id = project_stmt:value(0)
    end
    project_stmt:finalize()
    assert(active_project_id and active_project_id ~= "", "FATAL: Active sequence missing project_id (sequence_id=" .. tostring(active_sequence_id) .. ")")
    local project_record = Project.load(active_project_id)
    assert(project_record and project_record.name and project_record.name ~= "",
        string.format("Project '%s' missing name", tostring(active_project_id)))
    project_display_name = project_record.name

    -- Initialize CommandManager with database
    command_manager.init(db_module.get_connection(), active_sequence_id, active_project_id)
    logger.debug("layout", "CommandManager initialized with database")

    -- Initialize bug reporter (continuous background capture)
    local bug_reporter = require("bug_reporter.init")
    bug_reporter.init()
    logger.debug("layout", "Bug reporter initialized (background capture active)")
end


if not project_display_name then
    error("FATAL: Unable to resolve project display name for window title")
end

-- Create main window
logger.debug("layout", "About to create main window...")
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
logger.debug("layout", "Main window created successfully")
logger.debug("layout", "Applying main window stylesheet...")
assert(ui_constants and ui_constants.STYLES and type(ui_constants.STYLES.MAIN_WINDOW_TITLE_BAR) == "string" and ui_constants.STYLES.MAIN_WINDOW_TITLE_BAR ~= "",
    "MAIN_WINDOW_TITLE_BAR style is required for main window styling")
qt_set_widget_stylesheet(main_window, ui_constants.STYLES.MAIN_WINDOW_TITLE_BAR)
logger.debug("layout", "Stylesheet applied")
local window_title = project_display_name
qt_constants.PROPERTIES.SET_TITLE(main_window, window_title)
if qt_constants.PROPERTIES.SET_WINDOW_APPEARANCE then
    local ok, appearance_set = pcall(qt_constants.PROPERTIES.SET_WINDOW_APPEARANCE, main_window, "NSAppearanceNameDarkAqua")
    if not ok or appearance_set ~= true then
        logger.warn("layout", "Failed to set window appearance to dark mode")
    end
else
    logger.warn("layout", "Window appearance binding unavailable; title bar color may remain default")
end
qt_constants.PROPERTIES.SET_SIZE(main_window, 1600, 900)

-- Main vertical splitter (Top row | Timeline)
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

-- Top row: Horizontal splitter (Project Browser | Viewer | Inspector)
local top_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

-- 1. Project Browser (left) - create EARLY so menu system can reference it
local selection_hub = require("ui.selection_hub")
local project_browser_mod = require("ui.project_browser")
local panel_manager = require("ui.panel_manager")
local project_browser = project_browser_mod.create()
if project_browser_mod.set_project_title then
    project_browser_mod.set_project_title(project_display_name)
end

-- Initialize menu system AFTER project browser exists
logger.debug("layout", "Initializing menu system...")
local menu_system = require("core.menu_system")
menu_system.init(main_window, command_manager, project_browser_mod)

-- Load menus from XML
local menu_path = layout_dir .. "../../../menus.xml"
local menu_success, menu_error = menu_system.load_from_file(menu_path)
if menu_success then
    logger.debug("layout", "Menu system loaded successfully")
else
    logger.error("layout", "Failed to load menu system: " .. tostring(menu_error))
end

-- 2. Src/Timeline Viewer (center)
local viewer_panel_mod = require("ui.viewer_panel")
local viewer_panel = viewer_panel_mod.create()

-- 3. Inspector (right) - Create container for Lua inspector
local inspector_panel = qt_constants.WIDGET.CREATE_INSPECTOR()

-- 4. Timeline panel (create early, before inspector blocks execution)
local timeline_panel_mod = require("ui.timeline.timeline_panel")
local timeline_panel = timeline_panel_mod.create({
    sequence_id = active_sequence_id,
    project_id = active_project_id,
})

-- 5. Initialize keyboard shortcuts with the SAME timeline_state instance that timeline_panel uses
-- Note: Use F9 and F10 to add test clips via commands
local keyboard_shortcuts = require("core.keyboard_shortcuts")
local timeline_state_from_panel = timeline_panel_mod.get_state()
logger.debug("layout", string.format("timeline_state from panel = %s", tostring(timeline_state_from_panel)))
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
        logger.error("layout", "Inspector creation failed: " .. tostring(inspector_result))
    end

    -- Wire up timeline to inspector
    timeline_panel_mod.set_inspector(view)

    -- Wire up project browser to timeline for insert button
    project_browser_mod.set_timeline_panel(timeline_panel_mod)
    project_browser_mod.set_viewer_panel(viewer_panel_mod)
    project_browser_mod.set_inspector(view)

    -- Wire up menu system to timeline for Split command
    menu_system.set_timeline_panel(timeline_panel_mod)

    -- Route active selection through inspector via selection hub
    selection_hub.register_listener(function(items, panel_id)
        if view and view.update_selection then
            view.update_selection(items or {}, panel_id)
        end
    end)
    selection_hub.set_active_panel("timeline")
else
    logger.error("layout", "Inspector mount failed: " .. tostring(mount_result))
end

-- Register all panels with focus manager for visual indicators
focus_manager.register_panel("project_browser", project_browser, nil, "Project Browser", {
    focus_widgets = project_browser_mod.get_focus_widgets and project_browser_mod.get_focus_widgets() or nil
})
focus_manager.register_panel("viewer", viewer_panel, viewer_panel_mod.get_title_widget and viewer_panel_mod.get_title_widget() or nil, "Viewer")
focus_manager.register_panel("inspector", inspector_panel, nil, "Inspector", {
    focus_widgets = view.get_focus_widgets and view.get_focus_widgets() or nil
})
focus_manager.register_panel("timeline", timeline_panel, nil, "Timeline", {
    focus_widgets = timeline_panel_mod.get_focus_widgets and timeline_panel_mod.get_focus_widgets() or nil
})

panel_manager.init({
    main_splitter = main_splitter,
    top_splitter = top_splitter,
    focus_manager = focus_manager
})

-- Initialize all panels to unfocused state
focus_manager.initialize_all_panels()

-- Restore last-open sequence when available
local project_id = active_project_id
assert(project_id and project_id ~= "", "FATAL: missing active_project_id during sequence restore")
local sequences = db_module.load_sequences(project_id)

local function find_sequence_id(candidate_id, list)
    if not candidate_id or candidate_id == "" then
        return nil
    end
    for _, seq in ipairs(list or {}) do
        if seq.id == candidate_id then
            return candidate_id
        end
    end
    return nil
end

local last_sequence_id = nil
if db_module.get_project_setting then
    last_sequence_id = db_module.get_project_setting(project_id, "last_open_sequence_id")
end

local initial_sequence_id = find_sequence_id(last_sequence_id, sequences)
if not initial_sequence_id and #sequences > 0 then
    initial_sequence_id = sequences[1].id
end

if initial_sequence_id and project_browser_mod.focus_sequence then
    project_browser_mod.focus_sequence(initial_sequence_id)
    if focus_manager and focus_manager.focus_panel then
        focus_manager.focus_panel("timeline")
    end
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
-- Install global keyboard shortcut handler (skip in test mode to avoid crashes)
local test_mode_flag = os.getenv("JVE_TEST_MODE")
local is_test_mode = test_mode_flag == "1" or test_mode_flag == "true"

if not is_test_mode then
    _G.global_key_handler = function(event)
        return keyboard_shortcuts.handle_key(event)
    end
    qt_set_global_key_handler(main_window, "global_key_handler")
    logger.debug("layout", "Keyboard shortcuts installed")
else
    logger.warn("layout", "Keyboard shortcuts disabled (JVE_TEST_MODE set)")
end

-- Show window
qt_constants.DISPLAY.SHOW(main_window)
logger.info("layout", "Correct layout created: 3 panels top, timeline bottom")

-- Debug: Check actual widget sizes after window is shown
local window_w, window_h = qt_constants.PROPERTIES.GET_SIZE(main_window)
local timeline_w, timeline_h = qt_constants.PROPERTIES.GET_SIZE(timeline_panel)
local inspector_w, inspector_h = qt_constants.PROPERTIES.GET_SIZE(inspector_panel)
logger.debug("layout", string.format("Main window size: %dx%d", window_w, window_h))
logger.debug("layout", string.format("Timeline panel size: %dx%d", timeline_w, timeline_h))
logger.debug("layout", string.format("Inspector panel size: %dx%d", inspector_w, inspector_h))

return main_window
