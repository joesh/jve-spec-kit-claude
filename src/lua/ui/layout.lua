--- Add luarocks path for C modules (like lxp.so)
package.cpath = package.cpath .. ';' .. os.getenv('HOME') .. '/.luarocks/lib/lua/5.1/?.so'
package.path = package.path .. ';' .. os.getenv('HOME') .. '/.luarocks/share/lua/5.1/?.lua'
package.path = package.path .. ';' .. os.getenv('HOME') .. '/.luarocks/share/lua/5.1/?/init.lua'

local ui_constants = require("core.ui_constants")
local qt_constants = require("core.qt_constants")
local Project = require("models.project")
local Sequence = require("models.sequence")
local log = require("core.logger").for_area("ui")
local project_open = require("core.project_open")
local dkjson = require("dkjson")
local Signals = require("core.signals")

-- Project settings keys for window state persistence (single source of
-- truth in ui_constants; open_project.lua reads the same keys).
local WINDOW_GEOMETRY_KEY = ui_constants.WINDOW.GEOMETRY_SETTING_KEY
local SPLITTER_SIZES_KEY = ui_constants.WINDOW.SPLITTER_SIZES_SETTING_KEY
local panel_layout = require("ui.panel_layout")

-- Enable strict nil error handling - calling nil will raise an error with proper stack trace
debug.setmetatable(nil, {
  __call = function()
    error("attempt to call nil value", 2)
  end
})

-- Global error handler for automatic bug capture
local function global_error_handler(err)
    local stack_trace = debug.traceback(tostring(err), 2)
    log.error("FATAL ERROR: %s", tostring(err))
    log.error("%s", stack_trace)

    -- Capture bug report automatically on errors
    local ok, bug_reporter = pcall(require, "bug_reporter.init")
    if ok and bug_reporter then
        local test_path = bug_reporter.capture_on_error(tostring(err), stack_trace)
        if test_path then
            log.event("Bug report auto-captured: %s", tostring(test_path))
            log.event("Press F12 to review and submit")
        end
    end

    return tostring(err) .. "\n" .. stack_trace
end

-- Install global error handler
_G.error_handler = global_error_handler

-- Disable print buffering for immediate output
io.stdout:setvbuf("no")
io.stderr:setvbuf("no")

log.event("Creating layout...")
local layout_path = debug.getinfo(1, "S").source:sub(2)
local layout_dir = layout_path:match("(.*/)")

-- Initialize database connection
log.event("Initializing database...")
local db_module = require("core.database")

local project_display_name = nil
local active_project_id
local active_sequence_id

-- Initialize command_manager module reference (will be initialized later)
local command_manager = require("core.command_manager")

--- Open database, load project + sequence, init command manager.
-- Throws on any failure (corrupt DB, empty DB, missing project/sequence).
local function open_and_init_project(path)
    local db_success = project_open.open_project_database_or_prompt_cleanup(db_module, qt_constants, path)
    if not db_success then
        error("Failed to open database: " .. tostring(path))
    end
    log.event("Database connection established")

    -- Guard: detect empty DB (e.g. stale last_project_path, sqlite3 auto-created file)
    assert(db_module.has_projects(),
        "Database has no projects: " .. path)

    -- Load existing project (never create silently)
    local pid = db_module.get_current_project_id()
    local project = Project.load(pid)
    assert(project, "Failed to load project " .. tostring(pid) .. " from " .. path)

    -- Resolve the initial active sequence from saved tab state. If the
    -- project has no last_open_sequence_id, or it points to a deleted
    -- sequence, resolve returns nil and the editor opens in the
    -- no-active-sequence state (feature 010). No silent fallback.
    local sequence = Sequence.resolve_initial_for_project(pid)

    active_project_id = project.id
    project_display_name = project.name
    active_sequence_id = sequence and sequence.id
    log.event("Using project: %s", project.name)
    if sequence then
        log.event("Using sequence: %s", sequence.name)
    else
        log.event("No active sequence — opening in blank state")
    end

    -- Initialize CommandManager. With no active sequence, use the
    -- project-only path (no per-sequence stack activated).
    if active_sequence_id then
        command_manager.init(active_sequence_id, active_project_id)
    else
        command_manager.init_project_only(active_project_id)
    end
    log.event("CommandManager initialized with database")

    -- Pre-populate media status cache from DB BEFORE any clips render.
    -- Must happen here so ensure_clip_status finds persisted codec errors
    -- on first paint (not in the 50ms timer which fires after rendering).
    local media_status_init = require("core.media.media_status")
    -- Wire FS watcher callbacks once at app startup. Must happen before
    -- any watch_path() adds paths, or early watcher events get dropped.
    media_status_init.init_watcher()
    media_status_init.load_persisted(project.id)

    -- Persist last-opened path (for subsequent launches to skip welcome screen)
    local home = os.getenv("HOME")
    if home then
        local jve_dir = home .. "/.jve"
        local ok, err = qt_fs_mkdir_p(jve_dir)
        assert(ok, "layout: mkdir " .. jve_dir .. " failed: " .. tostring(err))
        local lf = io.open(home .. "/.jve/last_project_path", "w")
        if lf then
            lf:write(path)
            lf:close()
        end
    end

    -- Add to recent projects
    local recent_projects = require("core.recent_projects")
    recent_projects.add(project.name, path)

    -- Initialize peak cache and queue waveform generation for all audio media
    local peak_cache = require("core.media.peak_cache")
    peak_cache.init_for_project(pid)

    -- Initialize bug reporter (continuous background capture)
    local bug_reporter = require("bug_reporter.init")
    bug_reporter.init()
    log.event("Bug reporter initialized (background capture active)")
end

-- ---------------------------------------------------------------------------
-- Startup helpers
-- ---------------------------------------------------------------------------

--- Read ~/.jve/last_project_path; return path if file exists on disk, else nil.
local function try_last_project_path()
    local home = os.getenv("HOME")
    if not home then return nil end

    local f = io.open(home .. "/.jve/last_project_path", "r")
    if not f then return nil end

    local last_path = f:read("*a"):match("^%s*(.-)%s*$")  -- trim
    f:close()
    if not last_path or last_path == "" then return nil end

    local check = io.open(last_path, "rb")
    if not check then
        log.warn("Last project not found: %s", last_path)
        return nil
    end
    check:close()
    log.event("Reopening last project: %s", last_path)
    return last_path
end

--- Remove ~/.jve/last_project_path so next launch shows welcome screen.
local function clear_last_project_path()
    local home = os.getenv("HOME")
    if home then os.remove(home .. "/.jve/last_project_path") end
end

--- Dispatch a welcome screen action to a concrete project path.
-- @return string|nil: resolved path, or nil if user cancelled (caller re-shows welcome)
local function resolve_welcome_action(action, parent_dialog)
    local file_browser = require("core.file_browser")
    local new_project_cmd = require("core.commands.new_project")
    local home = os.getenv("HOME")
    assert(home and home ~= "", "resolve_welcome_action: HOME must be set")

    if action.action == "open" then
        return action.path

    elseif action.action == "open_browse" then
        local path = file_browser.open_file(
            "open_project", parent_dialog,
            "Open Project",
            "All Project Files (*.jvp *.drp);;JVE Projects (*.jvp);;Resolve Archives (*.drp);;All Files (*)",
            home ~= "" and (home .. "/Documents/JVE Projects") or "")
        if not path or path == "" then
            log.event("User cancelled file browser from welcome screen")
            return nil
        end
        return path

    elseif action.action == "new" then
        local result = new_project_cmd.show_dialog(parent_dialog)
        if not result then
            log.event("User cancelled new project from welcome screen")
            return nil
        end
        return result.project_path
    end

    return nil
end

--- Resolve format (DRP conversion if needed) then open project.
-- Throws on failure; returns nil if user cancelled conversion dialog.
local function resolve_and_open_project(path, parent_dialog)
    local open_project_cmd = require("core.commands.open_project")
    local resolved = open_project_cmd.resolve_format(path, parent_dialog)
    if not resolved then return nil end  -- user cancelled conversion
    open_and_init_project(resolved)
    return true
end

-- ---------------------------------------------------------------------------
-- Startup: resolve project path with retry loop
-- ---------------------------------------------------------------------------

-- Smoke test hook: schedule a clean exit once the event loop starts.
-- Fires regardless of which startup path is taken (project open or welcome screen).
if os.getenv("JVE_QUIT_AFTER_INIT") == "1" then
    local quit_delay = tonumber(os.getenv("JVE_QUIT_DELAY_MS")) or 2000
    log.event("JVE_QUIT_AFTER_INIT: will exit after %dms", quit_delay)
    qt_create_single_shot_timer(quit_delay, function()
        log.event("JVE_QUIT_AFTER_INIT: quiescent — exiting")
        os.exit(0)
    end)
end

-- Splitters + panel_manager are wired up here, BEFORE the startup
-- branch below, because the debug-terminal socket (spec 020) lets a
-- runner send `OpenProject` while the welcome dialog is still pumping
-- events. OpenProject's `post_open_init` reads `panel_manager.get_
-- persistable_sizes()` to snapshot the outgoing layout — without this
-- early init, that call hits a "not initialized" assert and the swap
-- fails halfway, leaving `record_engine.loaded_sequence_id` nil and
-- blocking every smoke test that runs through the singleton-JVE
-- runner. Panels themselves get added to the splitters further down
-- (line ~514); panel_manager.init only needs the splitters + a
-- focus_manager handle, so all of that can land up here.
local panel_manager = require("ui.panel_manager")
local focus_manager = require("ui.focus_manager")
local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
local top_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")
panel_manager.init({
    main_splitter = main_splitter,
    top_splitter = top_splitter,
    focus_manager = focus_manager,
})

-- Welcome screen handle — survives across retry iterations, destroyed after
-- main window is created and shown (no window gap).
local ws_handle = nil

local db_path = os.getenv("JVE_PROJECT_PATH")
if db_path then
    -- Test/CLI mode: crash on failure (unchanged)
    log.event("Using CLI project path: %s", tostring(db_path))
    open_and_init_project(db_path)
else
    local tried_last = false
    local startup_error = nil

    while true do
        local candidate = nil

        -- 1. Try last project (first iteration only)
        if not tried_last then
            tried_last = true
            candidate = try_last_project_path()
        end

        -- 2. If no candidate, show welcome screen
        if not candidate then
            local welcome_screen = require("ui.welcome_screen")
            ws_handle = ws_handle or welcome_screen.create()

            -- Show prior error if any
            if startup_error then
                qt_constants.DIALOG.SHOW_CONFIRM({
                    parent = ws_handle.dialog,
                    title = "Failed to Open Project",
                    message = startup_error,
                    icon = "warning",
                    confirm_text = "OK",
                })
                startup_error = nil
            end

            local action = welcome_screen.show(ws_handle)
            if not action then
                log.event("User quit from welcome screen")
                os.exit(0)
            end

            candidate = resolve_welcome_action(action, ws_handle.dialog)
            if not candidate then
                -- User cancelled sub-dialog (browse/new) — re-show welcome
                goto continue_loop
            end
        end

        -- 3. Re-show welcome screen (non-blocking) so it stays visible during conversion
        if ws_handle then
            qt_constants.DIALOG.SHOW(ws_handle.dialog, false)
        end

        -- 4. Try format resolution + open
        local open_ok, open_err = pcall(resolve_and_open_project, candidate, ws_handle and ws_handle.dialog)
        if open_ok and open_err then
            -- open_err is the return value (true) on success
            break
        end

        if open_ok and not open_err then
            -- resolve_and_open_project returned nil (user cancelled conversion)
            goto continue_loop
        end

        -- open failed — format error for next iteration
        log.error("Failed to open project '%s': %s", candidate, tostring(open_err))
        startup_error = string.format("Could not open:\n%s\n\n%s", candidate, tostring(open_err))
        clear_last_project_path()

        ::continue_loop::
    end
end

assert(project_display_name, "FATAL: Unable to resolve project display name for window title")

-- Update active_project_id when project changes (prevents stale ID writing to wrong DB)
Signals.connect("project_changed", function(new_project_id)
    log.event("project_changed: updating active_project_id %s → %s",
        tostring(active_project_id), tostring(new_project_id))
    active_project_id = new_project_id
end, 50)

-- Create main window
log.event("About to create main window...")
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
-- Feature 027 T010a: identify the JVE main window by objectName so the
-- bug-reporter capture path can find it regardless of focus state.
-- lua_grab_window (T010b) walks qApp->topLevelWidgets() looking for
-- this name and asserts if missing — fail-fast, never silently grab
-- whichever transient dialog happens to be focused.
qt_set_object_name(main_window, "JVEMainWindow")
log.event("Main window created successfully")
log.event("Applying main window stylesheet...")
assert(ui_constants and ui_constants.STYLES and type(ui_constants.STYLES.MAIN_WINDOW_TITLE_BAR) == "string" and ui_constants.STYLES.MAIN_WINDOW_TITLE_BAR ~= "",
    "MAIN_WINDOW_TITLE_BAR style is required for main window styling")
qt_set_widget_stylesheet(main_window, ui_constants.STYLES.MAIN_WINDOW_TITLE_BAR)
log.event("Stylesheet applied")
local window_title = project_display_name
qt_constants.PROPERTIES.SET_TITLE(main_window, window_title)
if qt_constants.PROPERTIES.SET_WINDOW_APPEARANCE then
    local ok, appearance_set = pcall(qt_constants.PROPERTIES.SET_WINDOW_APPEARANCE, main_window, "NSAppearanceNameDarkAqua")
    if not ok or appearance_set ~= true then
        log.warn("Failed to set window appearance to dark mode")
    end
else
    log.warn("Window appearance binding unavailable; title bar color may remain default")
end

-- Window geometry: restore saved or use defaults
-- Note: Don't persist on first launch - geometry isn't valid until after show()
local MIN_VALID_DIMENSION = ui_constants.WINDOW.MIN_VALID_DIMENSION
local saved_geo = db_module.get_project_setting(active_project_id, WINDOW_GEOMETRY_KEY)
if saved_geo and saved_geo.width and saved_geo.width > MIN_VALID_DIMENSION
    and saved_geo.height and saved_geo.height > MIN_VALID_DIMENSION then
    -- Restore saved geometry (with sanity check on dimensions)
    qt_constants.PROPERTIES.SET_GEOMETRY(main_window,
        saved_geo.x, saved_geo.y, saved_geo.width, saved_geo.height)
    log.event("Window geometry restored: %d,%d %dx%d",
        saved_geo.x, saved_geo.y, saved_geo.width, saved_geo.height)
else
    -- First launch or corrupt data: just set size, let OS position window
    qt_constants.PROPERTIES.SET_SIZE(main_window,
        ui_constants.WINDOW.DEFAULT_WIDTH, ui_constants.WINDOW.DEFAULT_HEIGHT)
    log.event("Window geometry set to default size %dx%d",
        ui_constants.WINDOW.DEFAULT_WIDTH, ui_constants.WINDOW.DEFAULT_HEIGHT)
end

-- Flag to prevent saving during initial layout (before window is fully shown)
local window_ready_to_save = false

-- Suppress geometry saves during project transitions.
-- Priority 2 fires before ANY widget-modifying handler (earliest is 10 = playback_controller).
-- When handlers tear down widgets, Qt recalculates layout → resize events → geometry handler
-- would persist degenerate splitter sizes (e.g. {1400,0,0,0}). Block that, re-enable after
-- the Qt event loop settles.
Signals.connect("project_changed", function()
    window_ready_to_save = false
    qt_create_single_shot_timer(50, function()
        window_ready_to_save = true
    end)
end, 2)

-- Splitters + panel_manager were wired up earlier (before the startup
-- branch) so that an out-of-band OpenProject from the debug-terminal
-- socket can land while welcome is still pumping events.

-- 1. Project Browser (left) - create EARLY so menu system can reference it
local selection_hub = require("ui.selection_hub")
local project_browser_mod = require("ui.project_browser")
local project_browser = project_browser_mod.create()
if project_browser_mod.set_project_title then
    project_browser_mod.set_project_title(project_display_name)
end

-- Initialize menu system AFTER project browser exists
log.event("Initializing menu system...")
local menu_system = require("core.menu_system")
menu_system.init(main_window, command_manager, project_browser_mod)

-- Load menus from XML
local menu_path = layout_dir .. "../../../menus.xml"
local menu_success, menu_error = menu_system.load_from_file(menu_path)
assert(menu_success, string.format(
    "layout: failed to load menu system from %s: %s", menu_path, tostring(menu_error)))

-- spec 023 — configure the Resolve bridge helper supervisor with the
-- path to tools/resolve-helper/helper.py. The supervisor only spawns
-- the Python helper on first request (lazy); configure() just records
-- the path so SendToResolve / SyncGradesFromResolve / etc. don't
-- assert "configure() must be called first" when invoked. Path is
-- repo-relative; bundle deploys must rsync tools/resolve-helper/ next
-- to src/lua under Contents/Resources/ for parity (CMakeLists addition
-- when the .app bundle ships the bridge — currently dev-only).
local helper_supervisor = require("core.resolve_bridge.helper_supervisor")
local helper_script_path = require("core.path_utils").resolve_repo_path("tools/resolve-helper/helper.py")
helper_supervisor.configure(helper_script_path)
log.event("Resolve bridge supervisor configured: %s", helper_script_path)
-- SPEC.keyboard metadata for non-menu commands surfaces in the dialog
-- via ShowKeyboardCustomization's eager load on open. No eager startup
-- load needed — keymap dispatch and dialog discovery are both fed
-- on-demand by command_registry.

-- 2. Source + Timeline Monitors (center)
local SequenceMonitor = require("ui.sequence_monitor")
local source_monitor = SequenceMonitor.new({ view_id = "source_monitor" })
local timeline_monitor = SequenceMonitor.new({ view_id = "timeline_monitor" })

-- Register monitors early so timeline_panel.create() can access them
panel_manager.register_sequence_monitor("source_monitor", source_monitor)
panel_manager.register_sequence_monitor("timeline_monitor", timeline_monitor)

-- Initialize audio. The 017 transport refactor moves ownership off the
-- "activate on focus" model; engines acquire the device on transport-start
-- (engine:play / shuttle / slow_play) via the synchronous handover in
-- audio_playback.halt_current / acquire_for. The legacy init_audio call
-- is kept for backward compat with any mock-injecting test, but we no
-- longer call activate_audio() here — audio is acquired lazily.
local PlaybackEngine = require("core.playback.playback_engine")
PlaybackEngine.init_audio(require("core.media.audio_playback"))

-- 3. Inspector (right) - Create container for Lua inspector
local inspector_panel = qt_constants.WIDGET.CREATE_INSPECTOR()

-- 4. Timeline panel (create early, before inspector blocks execution)
local timeline_panel_mod = require("ui.timeline.timeline_panel")
local timeline_panel = timeline_panel_mod.create({
    sequence_id = active_sequence_id,
    project_id = active_project_id,
})

-- 5. Initialize keyboard shortcuts.
local keyboard_shortcuts = require("core.keyboard_shortcuts")
keyboard_shortcuts.init(command_manager, project_browser_mod, timeline_panel_mod)

-- 5b. Create QShortcut objects from TOML bindings for Qt-native shortcut resolution.
-- Panel containers map context names to widgets; Qt fires the right shortcut based on focus.
local shortcut_registry = require("core.keyboard_shortcut_registry")
shortcut_registry.create_qt_shortcuts({
    window = main_window,
    timeline = timeline_panel,
    source_monitor = source_monitor:get_widget(),
    timeline_monitor = timeline_monitor:get_widget(),
    project_browser = project_browser,
})

-- 6. focus_manager was required earlier (paired with panel_manager.init);
-- below registers views/panels now that the actual panel widgets exist.

-- Register views for navigation (Find uses focus_manager.get_active_view())
focus_manager.register_view("timeline", timeline_panel_mod)
focus_manager.register_view("project_browser", project_browser_mod)
-- inspector registers itself from within mount() so its facade can stay at
-- three exports (spec 012 DR-THREE-EXPORTS) while still exposing a view-record
-- carrying view_id + show_find_bar.

-- 017 FR-009: focus changes do NOT touch audio ownership any more. Audio
-- ownership is structural (lives in core.media.audio_playback) and changes
-- only on transport-start through the synchronous halt/acquire handover.
-- The fullscreen follow-focus behavior is retained.
focus_manager.on_focus_change(function(_old_id, new_id)
    local fv = require("ui.fullscreen_viewer")
    if fv.is_active() then
        local view_id = (new_id == "timeline") and "timeline_monitor" or new_id
        fv.switch_viewer(view_id)
    end
end)

-- Initialize the rewritten Inspector (feature 012).
-- Public API: three functions — mount, update_selection, get_focus_widgets.
-- mount() registers the focus_manager view-record internally so the facade
-- can stay at three exports (spec 012 DR-THREE-EXPORTS).
local inspector = require("ui.inspector")
inspector.mount(inspector_panel)

-- Wire project browser to timeline for insert button.
project_browser_mod.set_timeline_panel(timeline_panel_mod)

-- Wire menu system to timeline for Split command.
menu_system.set_timeline_panel(timeline_panel_mod)

-- Route active selection through inspector via selection hub.
selection_hub.register_listener(function(items, panel_id)
    inspector.update_selection(items or {}, panel_id)
end)
-- The timeline (record) monitor renders the timeline's output; it owns no
-- selection of its own, so focusing it keeps the timeline's selection active.
selection_hub.register_alias("timeline_monitor", "timeline")
selection_hub.set_active_panel("timeline")

-- Install global click-to-focus before registering panels
focus_manager.install_click_to_focus()

-- Register all panels with focus manager for visual indicators
focus_manager.register_panel("project_browser", project_browser, nil, "Project Browser", {
    focus_widgets = project_browser_mod.get_focus_widgets and project_browser_mod.get_focus_widgets() or nil
})
focus_manager.register_panel("source_monitor", source_monitor:get_widget(), source_monitor:get_title_widget(), "Source")
focus_manager.register_panel("timeline_monitor", timeline_monitor:get_widget(), timeline_monitor:get_title_widget(), "Timeline Monitor")
focus_manager.register_panel("inspector", inspector_panel, nil, "Inspector", {
    focus_widgets = inspector.get_focus_widgets()
})
focus_manager.register_panel("timeline", timeline_panel, nil, "Timeline", {
    focus_widgets = timeline_panel_mod.get_focus_widgets and timeline_panel_mod.get_focus_widgets() or nil
})

-- Initialize all panels to unfocused state
focus_manager.initialize_all_panels()

-- Add the top panels in panel_layout's declared order. The widget-to-id map
-- and panel_layout.TOP_PANELS are the two halves of one contract: the splitter
-- child order MUST match the topology panel_manager indexes against. Driving
-- the add loop from panel_layout (rather than a hand-ordered call list) keeps
-- them from silently desyncing.
local top_widgets_by_id = {
    project_browser  = project_browser,
    source_monitor   = source_monitor:get_widget(),
    timeline_monitor = timeline_monitor:get_widget(),
    inspector        = inspector_panel,
}
for _, panel in ipairs(panel_layout.TOP_PANELS) do
    local widget = assert(top_widgets_by_id[panel.id],
        "layout: no widget for declared top panel '" .. panel.id .. "'")
    qt_constants.LAYOUT.ADD_WIDGET(top_splitter, widget)
end

-- Add top row and timeline to main splitter
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, top_splitter)
qt_constants.LAYOUT.ADD_WIDGET(main_splitter, timeline_panel)

-- Set as central widget
qt_constants.LAYOUT.SET_CENTRAL_WIDGET(main_window, main_splitter)

-- Restore last-open sequence AFTER widget tree is assembled.
-- The seek in load_sequence delivers a frame to the GPUVideoSurface via Metal.
-- If the surface isn't in the visible widget tree yet, the rendered drawable
-- is discarded when the widget is reparented into the layout.
local project_id = active_project_id
assert(project_id and project_id ~= "", "FATAL: missing active_project_id during sequence restore")
local sequences = db_module.load_sequences(project_id)

-- Pick an initial sequence id that is safe to pass to timeline_state.init:
-- must exist AND must be a record (kind='sequence'), never a master. FR-005:
-- masters can never be the active edit target. A poisoned
-- `last_open_sequence_id` (pointing at a master) is silently ignored so
-- the editor falls back to the no-active-sequence state instead of
-- crashing or corrupting the setting further.
local function find_sequence_id(candidate_id, list)
    if not candidate_id or candidate_id == "" then
        return nil
    end
    for _, seq in ipairs(list or {}) do
        if seq.id == candidate_id then
            if seq.kind == "master" then
                log.warn("last_open_sequence_id=%s is a master sequence; "
                    .. "ignoring (FR-005 — masters cannot be the active edit target)",
                    tostring(candidate_id))
                return nil
            end
            return candidate_id
        end
    end
    return nil
end

local last_sequence_id = nil
if db_module.get_project_setting then
    last_sequence_id = db_module.get_project_setting(project_id, "last_open_sequence_id")
end

-- No silent fallback: if last_open_sequence_id is unset or refers to a
-- sequence that no longer exists, initial_sequence_id stays nil and the
-- editor opens in the no-active-sequence state (feature 010, FR-004).
local initial_sequence_id = find_sequence_id(last_sequence_id, sequences)

-- Restore the timeline tab strip from its serialized blob — the single
-- source of truth for which tabs are open, their order, the source tab
-- (loaded master or empty), and which side (record/source) was displayed.
-- Supersedes the former open_sequence_ids / source_tab_sequence_id /
-- displayed_tab_kind trio. The initial record tab + active pointer are
-- already established by timeline_state.init (via command_manager.init);
-- this replays the rest incrementally so open_tabs stays consistent with
-- the bootstrap-created tab.
local timeline_state = require("ui.timeline.timeline_state")
local strip_blob = timeline_state.get_persisted_tab_strip_blob()
if strip_blob and type(strip_blob.tabs) == "table" then
    -- Decode the blob into restore intent (record ids, the source tab, the
    -- displayed side). Strip-format knowledge lives in the strip module; the
    -- cross-layer replay below — which spans state/panel/source_viewer — is
    -- the composition root's job.
    local TimelineTabStrip = require("ui.timeline.timeline_tab_strip")
    local plan = TimelineTabStrip.decode_blob(strip_blob)

    -- Empty source tab: open it in the strip (no display yet) so it
    -- materializes as a closable tab below.
    if plan.source_is_empty then
        timeline_state.get_tab_strip():ensure_empty_source_tab()
    end

    -- Open each saved record tab (the initial one already exists).
    for _, seq_id in ipairs(plan.record_ids) do
        if seq_id ~= initial_sequence_id then
            local tab_ok, tab_err = pcall(timeline_panel_mod.open_tab, seq_id)
            if not tab_ok then
                log.error("Failed to create tab for sequence %s: %s",
                    seq_id, tostring(tab_err))
            end
        end
    end

    -- Reload the source monitor's master so transport + the source view come
    -- back from a quit (the strip tab's cache is hydrated, but the source
    -- MONITOR is owned by source_viewer). FR-001b auto-switch makes this the
    -- displayed side when a master was persisted.
    if plan.source_seq then
        require("ui.source_viewer").load_master_clip(plan.source_seq)
        log.event("Restored source monitor master: %s", plan.source_seq)
    end

    -- Match the panel's visual tab order to the strip (source first, then
    -- saved record order).
    timeline_panel_mod.restore_tabs_from_strip()

    -- Restore the displayed side. Record-displayed is already shown by init;
    -- flip to the source side only when the user left off there.
    if plan.displayed_kind == "source" then
        if plan.displayed_seq and plan.displayed_seq ~= "" then
            timeline_state.switch_to_source_tab(plan.displayed_seq)
            log.event("Restored displayed tab kind=source seq=%s", plan.displayed_seq)
        elseif plan.source_is_empty then
            timeline_state.show_empty_source_tab()
            log.event("Restored displayed empty source tab")
        end
    end
end

if initial_sequence_id and project_browser_mod.focus_sequence then
    project_browser_mod.focus_sequence(initial_sequence_id)
    if focus_manager and focus_manager.focus_panel then
        focus_manager.focus_panel("timeline")
    end
end

-- Override the bootstrap default focus with the per-project saved one.
-- Runs after the "timeline" default above so first-open (no setting yet)
-- still lands on the timeline; a subsequent reopen lands wherever the
-- user last clicked. Unknown saved ids no-op (panel renamed/removed).
if focus_manager and focus_manager.restore_persisted_focus then
    focus_manager.restore_persisted_focus(project_id)
end

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
    log.event("Keyboard shortcuts installed")
else
    log.warn("Keyboard shortcuts disabled (JVE_TEST_MODE set)")
end

-- Save window state function (saves geometry + splitter sizes)
local function save_window_state()
    if not active_project_id then return end
    if not window_ready_to_save then return end  -- Skip during initial layout

    local x, y, w, h = qt_constants.PROPERTIES.GET_GEOMETRY(main_window)
    -- Sanity check: don't save invalid geometry
    if w < MIN_VALID_DIMENSION or h < MIN_VALID_DIMENSION then return end

    db_module.set_project_setting(active_project_id, WINDOW_GEOMETRY_KEY, {
        x = x, y = y, width = w, height = h
    })

    local sizes = panel_manager.get_persistable_sizes()
    assert(sizes, "save_window_state: panel_manager has no splitters but "
        .. "window_ready_to_save is true — bootstrap order violation")
    db_module.set_project_setting(active_project_id, SPLITTER_SIZES_KEY, sizes)

    log.detail("Window state saved: geo=%d,%d %dx%d, splitters top=%s main=%s",
        x, y, w, h, dkjson.encode(sizes.top), dkjson.encode(sizes.main))
end

-- Register save-on-change handlers (persists even if app is killed)
_G["__jve_save_window_state"] = save_window_state
if not is_test_mode then
    qt_set_splitter_moved_handler(top_splitter, "__jve_save_window_state")
    qt_set_splitter_moved_handler(main_splitter, "__jve_save_window_state")
    qt_constants.SIGNAL.SET_GEOMETRY_CHANGE_HANDLER(main_window, "__jve_save_window_state")
    log.event("Window state save handlers registered (geometry + splitters)")
end

-- Show window (pcall: corrupt DB data must not prevent editor from launching)
local show_ok, show_err = pcall(qt_constants.DISPLAY.SHOW, main_window)
if not show_ok then
    log.error("Window SHOW triggered error (corrupt data?): %s", tostring(show_err))
end
log.event("Layout created: 4 panels top (browser, source, timeline viewer, inspector) + timeline bottom")

-- Destroy welcome screen AFTER main window is visible (no window gap)
if ws_handle then
    local welcome_screen = require("ui.welcome_screen")
    welcome_screen.destroy(ws_handle)
    log.event("Welcome screen destroyed (main window visible)")
end

-- Restore splitter sizes AFTER window is shown (Qt needs layout computed
-- first). Deferred by a short timer so Qt has settled the initial layout
-- before we apply saved sizes. restore_or_default validates the saved record
-- against the panel topology and falls back to defaults for missing/corrupt/
-- degenerate data — the single restore contract shared with project switch
-- (core/commands/open_project.lua). No 3→4 migration: a stale record from an
-- earlier panel count fails validation and resets to defaults (rule 2.15).
local saved_splitters = db_module.get_project_setting(active_project_id, SPLITTER_SIZES_KEY)
qt_create_single_shot_timer(ui_constants.WINDOW.SPLITTER_RESTORE_DELAY_MS, function()
    local applied, defaulted = panel_manager.restore_or_default(saved_splitters)
    if applied then
        if defaulted then
            db_module.set_project_setting(active_project_id, SPLITTER_SIZES_KEY, applied)
        end
        log.event("Splitter sizes %s: top=%s main=%s",
            defaulted and "defaulted" or "restored",
            dkjson.encode(applied.top), dkjson.encode(applied.main))
    end

    -- Tab restoration now happens synchronously before window SHOW — see
    -- "Restored %d tabs in saved order" above. Splitter restoration stays
    -- deferred because Qt needs post-layout widget sizes.

    -- Restore edit history window if it was open last session
    local edit_history_ok, edit_history = pcall(require, "ui.edit_history_window")
    if edit_history_ok and edit_history.restore_if_open then
        pcall(edit_history.restore_if_open, command_manager)
    end

    window_ready_to_save = true
    log.event("Window state persistence enabled")

    -- Defer background codec probe so it doesn't block the first paint
    local media_status = require("core.media.media_status")
    qt_create_single_shot_timer(0, function()
        media_status.start_background_probe(initial_sequence_id)
    end)
end)

-- Debug: Check actual widget sizes after window is shown
local window_w, window_h = qt_constants.PROPERTIES.GET_SIZE(main_window)
local timeline_w, timeline_h = qt_constants.PROPERTIES.GET_SIZE(timeline_panel)
local inspector_w, inspector_h = qt_constants.PROPERTIES.GET_SIZE(inspector_panel)
log.event("Main window size: %dx%d", window_w, window_h)
log.event("Timeline panel size: %dx%d", timeline_w, timeline_h)
log.event("Inspector panel size: %dx%d", inspector_w, inspector_h)

-- Shutdown hook: called by main.cpp via aboutToQuit before Qt objects
-- are destroyed. Delegates to core.app_lifecycle so the sequence is
-- unit-testable without booting Qt — see core/app_lifecycle.lua for
-- the ordered shutdown steps and rationale.
_G.__jve_shutdown = require("core.app_lifecycle").shutdown

-- Export widget references for UI tests (main.cpp uses s_lastCreatedMainWindow, not this return value)
return {
    main_window = main_window,
    main_splitter = main_splitter,
    top_splitter = top_splitter,
    project_browser = project_browser,
    source_monitor = source_monitor,
    timeline_monitor = timeline_monitor,
    inspector_panel = inspector_panel,
    timeline_panel = timeline_panel,
    active_project_id = active_project_id,
    active_sequence_id = active_sequence_id,
}
