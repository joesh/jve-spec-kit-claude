--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~359 LOC
-- Volatility: unknown
--
-- @file layout.lua
-- Original intent (unreviewed):
-- Add luarocks path for C modules (like lxp.so)
package.cpath = package.cpath .. ';' .. os.getenv('HOME') .. '/.luarocks/lib/lua/5.1/?.so'
package.path = package.path .. ';' .. os.getenv('HOME') .. '/.luarocks/share/lua/5.1/?.lua'
package.path = package.path .. ';' .. os.getenv('HOME') .. '/.luarocks/share/lua/5.1/?/init.lua'

local ui_constants = require("core.ui_constants")
local qt_constants = require("core.qt_constants")
local Project = require("models.project")
local Sequence = require("models.sequence")
local logger = require("core.logger")
local project_open = require("core.project_open")
local dkjson = require("dkjson")
local Signals = require("core.signals")

-- Project settings keys for window state persistence
local WINDOW_GEOMETRY_KEY = "window_geometry"
local SPLITTER_SIZES_KEY = "splitter_sizes"

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

-- Determine database path: test env → last project → welcome screen
local db_path = os.getenv("JVE_PROJECT_PATH")
if db_path then
    logger.info("layout", "Using CLI project path: " .. tostring(db_path))
else
    local home = os.getenv("HOME")

    -- Try last-opened project first
    local last_project_file = home .. "/.jve/last_project_path"
    local f = io.open(last_project_file, "r")
    if f then
        local last_path = f:read("*a"):match("^%s*(.-)%s*$")  -- trim
        f:close()
        if last_path and last_path ~= "" then
            local check = io.open(last_path, "rb")
            if check then
                check:close()
                db_path = last_path
                logger.info("layout", "Reopening last project: " .. db_path)
            else
                logger.warn("layout", "Last project not found: " .. last_path)
            end
        end
    end

    -- No last project → show welcome screen
    if not db_path then
        local welcome_screen = require("ui.welcome_screen")
        local file_browser = require("core.file_browser")
        local new_project_cmd = require("core.commands.new_project")

        local action = welcome_screen.show()

        if not action then
            logger.info("layout", "User quit from welcome screen")
            os.exit(0)
        elseif action.action == "open" then
            db_path = action.path
            logger.info("layout", "Welcome: opening recent project: " .. db_path)
        elseif action.action == "open_browse" then
            db_path = file_browser.open_file(
                "open_project", nil,
                "Open Project",
                "JVE Projects (*.jvp);;All Files (*)",
                home .. "/Documents/JVE Projects")
            if not db_path or db_path == "" then
                logger.info("layout", "User cancelled file browser from welcome screen")
                os.exit(0)
            end
            logger.info("layout", "Welcome: opening browsed project: " .. db_path)
        elseif action.action == "new" then
            local result = new_project_cmd.show_dialog(nil)
            if not result then
                logger.info("layout", "User cancelled new project from welcome screen")
                os.exit(0)
            end
            db_path = result.project_path
            logger.info("layout", "Welcome: created new project: " .. db_path)
        end
    end
end

assert(db_path and db_path ~= "", "FATAL: No project path resolved at startup")

local project_display_name = nil
local active_project_id
local active_sequence_id

-- Initialize command_manager module reference (will be initialized later)
local command_manager = require("core.command_manager")

-- Open database connection (schema is applied automatically by database.init via load_main_schema)
local db_success = project_open.open_project_database_or_prompt_cleanup(db_module, qt_constants, db_path)
if not db_success then
    logger.error("layout", "Failed to open database connection; exiting")
    os.exit(1)
else
    logger.debug("layout", "Database connection established")

    -- Guard: detect empty DB (e.g. stale last_project_path, sqlite3 auto-created file)
    if not db_module.has_projects() then
        logger.warn("layout", "Database has no projects: " .. db_path)
        -- Self-heal: clear stale last_project_path so next launch shows welcome screen
        local home = os.getenv("HOME")
        if home then
            os.remove(home .. "/.jve/last_project_path")
            logger.info("layout", "Cleared stale last_project_path; re-launch to see welcome screen")
        end
        error("Database at " .. db_path .. " has no projects. Stale reference cleared — please re-launch.")
    end

    -- Load existing project (never create silently)
    local pid = db_module.get_current_project_id()
    local project = Project.load(pid)
    assert(project, "FATAL: Failed to load project " .. tostring(pid) .. " from " .. db_path)

    -- Find best sequence: last-open or most recent
    local sequence
    local last_seq_id = db_module.get_project_setting(pid, "last_open_sequence_id")
    if last_seq_id and last_seq_id ~= "" then
        sequence = Sequence.load(last_seq_id)
    end
    if not sequence then
        sequence = Sequence.find_most_recent()
    end
    assert(sequence, "FATAL: No sequences in project " .. db_path)

    active_project_id = project.id
    project_display_name = project.name
    active_sequence_id = sequence.id
    logger.debug("layout", "Using project: " .. project.name)
    logger.debug("layout", "Using sequence: " .. sequence.name)

    -- Initialize CommandManager
    command_manager.init(active_sequence_id, active_project_id)
    logger.debug("layout", "CommandManager initialized with database")

    -- Persist last-opened path (for subsequent launches to skip welcome screen)
    local home = os.getenv("HOME")
    if home then
        os.execute('mkdir -p "' .. home .. '/.jve"')
        local lf = io.open(home .. "/.jve/last_project_path", "w")
        if lf then
            lf:write(db_path)
            lf:close()
        end
    end

    -- Add to recent projects
    local recent_projects = require("core.recent_projects")
    recent_projects.add(project.name, db_path)

    -- Initialize bug reporter (continuous background capture)
    local bug_reporter = require("bug_reporter.init")
    bug_reporter.init()
    logger.debug("layout", "Bug reporter initialized (background capture active)")
end

-- Update active_project_id when project changes (prevents stale ID writing to wrong DB)
Signals.connect("project_changed", function(new_project_id)
    logger.info("layout", "project_changed: updating active_project_id "
        .. tostring(active_project_id) .. " → " .. tostring(new_project_id))
    active_project_id = new_project_id
end, 50)


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

-- Window geometry: restore saved or use defaults
-- Note: Don't persist on first launch - geometry isn't valid until after show()
local saved_geo = db_module.get_project_setting(active_project_id, WINDOW_GEOMETRY_KEY)
if saved_geo and saved_geo.width and saved_geo.width > 100 and saved_geo.height and saved_geo.height > 100 then
    -- Restore saved geometry (with sanity check on dimensions)
    qt_constants.PROPERTIES.SET_GEOMETRY(main_window,
        saved_geo.x, saved_geo.y, saved_geo.width, saved_geo.height)
    logger.debug("layout", string.format("Window geometry restored: %d,%d %dx%d",
        saved_geo.x, saved_geo.y, saved_geo.width, saved_geo.height))
else
    -- First launch or corrupt data: just set size, let OS position window
    qt_constants.PROPERTIES.SET_SIZE(main_window, 1600, 900)
    logger.debug("layout", "Window geometry set to default size 1600x900")
end

-- Flag to prevent saving during initial layout (before window is fully shown)
local window_ready_to_save = false

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

-- 2. Source + Timeline Monitors (center)
local SequenceMonitor = require("ui.sequence_monitor")
local source_monitor = SequenceMonitor.new({ view_id = "source_monitor" })
local timeline_monitor = SequenceMonitor.new({ view_id = "timeline_monitor" })

-- Register monitors early so timeline_panel.create() can access them
panel_manager.register_sequence_monitor("source_monitor", source_monitor)
panel_manager.register_sequence_monitor("timeline_monitor", timeline_monitor)

-- Initialize audio: PlaybackEngine needs the audio module reference,
-- and timeline_monitor owns audio by default (source_monitor activates on focus).
local PlaybackEngine = require("core.playback.playback_engine")
PlaybackEngine.init_audio(require("core.media.audio_playback"))
timeline_monitor.engine:activate_audio()

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

-- Audio follows focus: transfer audio ownership when switching between monitors.
-- Non-monitor panels (browser, inspector) keep the last monitor's audio active.
focus_manager.on_focus_change(function(old_id, new_id)
    local monitor_for = {
        source_monitor = source_monitor,
        timeline_monitor = timeline_monitor,
        timeline = timeline_monitor,
    }
    local new_mon = monitor_for[new_id]
    if not new_mon then return end

    source_monitor.engine:deactivate_audio()
    timeline_monitor.engine:deactivate_audio()
    new_mon.engine:activate_audio()
end)

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
focus_manager.register_panel("source_monitor", source_monitor:get_widget(), source_monitor:get_title_widget(), "Source")
focus_manager.register_panel("timeline_monitor", timeline_monitor:get_widget(), timeline_monitor:get_title_widget(), "Timeline Monitor")
focus_manager.register_panel("inspector", inspector_panel, nil, "Inspector", {
    focus_widgets = view.get_focus_widgets and view.get_focus_widgets() or nil
})
focus_manager.register_panel("timeline", timeline_panel, nil, "Timeline", {
    focus_widgets = timeline_panel_mod.get_focus_widgets and timeline_panel_mod.get_focus_widgets() or nil
})

panel_manager.init({
    main_splitter = main_splitter,
    top_splitter = top_splitter,
    focus_manager = focus_manager,
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

-- Add four panels to top splitter
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, project_browser)
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, source_monitor:get_widget())
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, timeline_monitor:get_widget())
qt_constants.LAYOUT.ADD_WIDGET(top_splitter, inspector_panel)

-- Add top row and timeline to main splitter
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, top_splitter)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, timeline_panel)

-- Set as central widget
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)

-- Install global keyboard shortcut handler (skip in test mode to avoid crashes)
local test_mode_flag = os.getenv("JVE_TEST_MODE")
local is_test_mode = test_mode_flag == "1" or test_mode_flag == "true"

if not is_test_mode then
    _G.global_key_handler = function(event)
        return keyboard_shortcuts.handle_key(event)
    end
    _G.global_key_release_handler = function(event)
        return keyboard_shortcuts.handle_key_release(event)
    end
    qt_set_global_key_handler(main_window, "global_key_handler")
    logger.debug("layout", "Keyboard shortcuts installed")
else
    logger.warn("layout", "Keyboard shortcuts disabled (JVE_TEST_MODE set)")
end

-- Save window state function (saves geometry + splitter sizes)
local function save_window_state()
    if not active_project_id then return end
    if not window_ready_to_save then return end  -- Skip during initial layout

    local x, y, w, h = qt_constants.PROPERTIES.GET_GEOMETRY(main_window)
    -- Sanity check: don't save invalid geometry
    if w < 100 or h < 100 then return end

    db_module.set_project_setting(active_project_id, WINDOW_GEOMETRY_KEY, {
        x = x, y = y, width = w, height = h
    })

    local sizes = panel_manager.get_persistable_sizes()
    db_module.set_project_setting(active_project_id, SPLITTER_SIZES_KEY, sizes)

    logger.trace("layout", string.format("Window state saved: geo=%d,%d %dx%d, splitters top=%s main=%s",
        x, y, w, h, dkjson.encode(sizes.top), dkjson.encode(sizes.main)))
end

-- Register save-on-change handlers (persists even if app is killed)
_G["__jve_save_window_state"] = save_window_state
if not is_test_mode then
    qt_set_splitter_moved_handler(top_splitter, "__jve_save_window_state")
    qt_set_splitter_moved_handler(main_splitter, "__jve_save_window_state")
    qt_constants.SIGNAL.SET_GEOMETRY_CHANGE_HANDLER(main_window, "__jve_save_window_state")
    logger.debug("layout", "Window state save handlers registered (geometry + splitters)")
end

-- Show window
qt_constants.DISPLAY.SHOW(main_window)
logger.info("layout", "Layout created: 4 panels top (browser, source, timeline viewer, inspector) + timeline bottom")

-- Restore splitter sizes AFTER window is shown (Qt needs layout to be computed first)
-- Use a short timer to let the layout settle before applying saved sizes
local saved_splitters = db_module.get_project_setting(active_project_id, SPLITTER_SIZES_KEY)
qt_create_single_shot_timer(50, function()
    -- Migrate saved 3-panel top splitter to 4-panel
    if saved_splitters and saved_splitters.top and #saved_splitters.top == 3 then
        local old = saved_splitters.top
        -- Split old viewer (index 2) evenly into source_monitor + timeline_monitor
        local half = math.floor(old[2] / 2)
        saved_splitters.top = {old[1], half, old[2] - half, old[3]}
        logger.info("layout", "Migrated 3-panel splitter to 4-panel")
    end

    if not saved_splitters then
        -- First launch: set defaults and persist
        qt_constants.LAYOUT.SET_SPLITTER_SIZES(top_splitter, {350, 350, 350, 350})
        qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {450, 450})
        db_module.set_project_setting(active_project_id, SPLITTER_SIZES_KEY, {
            top = {350, 350, 350, 350}, main = {450, 450}
        })
        logger.debug("layout", "Splitter sizes initialized to defaults")
    else
        -- Subsequent launches: validate and restore
        assert(saved_splitters.top and #saved_splitters.top == 4,
            string.format("layout: splitter_sizes.top corrupt (expected 4), got: %s", dkjson.encode(saved_splitters)))
        assert(saved_splitters.main and #saved_splitters.main == 2,
            string.format("layout: splitter_sizes.main corrupt, got: %s", dkjson.encode(saved_splitters)))
        qt_constants.LAYOUT.SET_SPLITTER_SIZES(top_splitter, saved_splitters.top)
        qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, saved_splitters.main)
        logger.debug("layout", string.format("Splitter sizes restored: top=%s, main=%s",
            dkjson.encode(saved_splitters.top), dkjson.encode(saved_splitters.main)))
    end

    -- Now that layout is settled, enable save-on-change
    window_ready_to_save = true
    logger.debug("layout", "Window state persistence enabled")
end)

-- Debug: Check actual widget sizes after window is shown
local window_w, window_h = qt_constants.PROPERTIES.GET_SIZE(main_window)
local timeline_w, timeline_h = qt_constants.PROPERTIES.GET_SIZE(timeline_panel)
local inspector_w, inspector_h = qt_constants.PROPERTIES.GET_SIZE(inspector_panel)
logger.debug("layout", string.format("Main window size: %dx%d", window_w, window_h))
logger.debug("layout", string.format("Timeline panel size: %dx%d", timeline_w, timeline_h))
logger.debug("layout", string.format("Inspector panel size: %dx%d", inspector_w, inspector_h))

return main_window
