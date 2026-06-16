--- Open Project Command - Interactive dialog and non-interactive project loading
--
-- Responsibilities:
-- - OpenProject: Shows file picker when interactive=true, opens project database
-- - Handles multiple formats: .jvp (native), .drp (Resolve archive → conversion)
--
-- Non-goals:
-- - Undo support (opening a project is an application-level action, not undoable)
-- - Creating new projects (see NewProject command)
--
-- Invariants:
-- - Requires project_path (or gathered from dialog)
-- - After opening, command_manager is re-initialized with new database
-- - .drp files trigger conversion dialog before opening
--
-- Size: ~250 LOC
-- Volatility: low
--
-- @file open_project.lua
local M = {}
local log = require("core.logger").for_area("media")
local project_open = require("core.project_open")
local file_browser = require("core.file_browser")
local recent_projects = require("core.recent_projects")

-- ---------------------------------------------------------------------------
-- Format Detection
-- ---------------------------------------------------------------------------

local function get_file_extension(path)
    if not path then return nil end
    return path:match("%.([^%.]+)$")
end

local function detect_project_format(path)
    local ext = get_file_extension(path)
    if not ext then return "unknown" end
    ext = ext:lower()

    if ext == "jvp" then
        return "jvp"
    elseif ext == "drp" then
        return "drp"
    elseif ext == "prproj" then
        return "prproj"
    elseif ext == "db" or ext == "resolve" then
        return "resolve_db"
    else
        return "unknown"
    end
end

-- ---------------------------------------------------------------------------
-- DRP → JVP conversion (private to OpenProject)
-- ---------------------------------------------------------------------------
-- The convert lifecycle lives here, not in drp_importer, because it
-- owns DB-lifecycle: filesystem wipe + active-connection swap + signal
-- cascade. drp_importer is the format-knowledge layer (parse + merge +
-- derive); see specs/020-debug-terminal/phase1-test-overhaul.md for the
-- decision rationale.

-- Report progress through the caller's optional callback and raise a
-- cancellation sentinel if it returned the cancel string. Bare
-- table-with-flag (no message) keeps error()'s level 0 from emitting
-- a traceback for what is a normal control-flow event, not a fault.
local function report_progress(progress_cb, pct, text)
    if progress_cb == nil then return end
    if progress_cb(pct, text) == "cancel" then
        error({ cancelled = true }, 0)
    end
end

-- Build a sub-phase progress callback that maps the parser/importer's
-- 0-100 progress onto a slice of the overall 0-100 range. Returns nil
-- when no outer callback was supplied — drp_importer treats nil as
-- "don't report sub-progress" and skips its Qt event-pump path.
local function remap_progress(progress_cb, base_pct, range_pct)
    if not progress_cb then return nil end
    return function(sub_pct, text)
        progress_cb(base_pct + math.floor(sub_pct * range_pct / 100), text)
    end
end

-- The destination .jvp belongs entirely to the project we're about to
-- write. Stale -shm / -wal from a prior failed convert would otherwise
-- replay junk onto the fresh schema on next open.
local function wipe_destination(jvp_path)
    os.remove(jvp_path)
    os.remove(jvp_path .. "-shm")
    os.remove(jvp_path .. "-wal")
end

-- Project:save returns false on no-connection rather than asserting, so
-- the caller must check and surface — silent skip would leave the .jvp
-- with media rows pointing at a non-existent project_id.
local function create_project_record(parse_result, settings)
    local Project = require("models.project")
    local json    = require("dkjson")
    local project = Project.create(parse_result.project.name, {
        settings            = json.encode(settings),
        fps_mismatch_policy = "resample",
    })
    assert(project:save(), string.format(
        "create_project_record: Project:save returned false for %q (id=%s)",
        project.name, project.id))
    log.event("Created project: %s (%dx%d @ %sfps)",
        project.name, settings.width, settings.height,
        tostring(settings.frame_rate))
    return project
end

local function persist_tab_state(project_id, tabs)
    local database = require("core.database")
    -- last_open_sequence_id stays its own setting (secondary consumers:
    -- codec-probe priority, initial-sequence resolution read it without the
    -- strip). The open-tab list lives in the timeline_tab_strip blob — the
    -- single source of truth restore reads (supersedes open_sequence_ids).
    database.set_project_setting(project_id, "last_open_sequence_id", tabs.active_sequence_id)
    local TimelineTabStrip = require("ui.timeline.timeline_tab_strip")
    local blob = TimelineTabStrip.build_record_only_blob(
        tabs.open_sequence_ids, tabs.active_sequence_id)
    database.set_project_setting(project_id, "timeline_tab_strip", blob)
end

-- Synthetic command in history records the project's origin (chain of
-- custody): sequence_number=0, parent=-1 means "visible in history,
-- invisible to undo/redo." The command_type literal is the DOMAIN name
-- for the operation (e.g. Resolve-project import) — not the command-
-- dispatch name; OpenProject is the command that performs it.
local function record_import_provenance(project_id, command_type, source_path, source_name, path_key)
    local params = { source_name = source_name }
    params[path_key] = source_path
    require("command").insert_provenance(command_type, project_id, params)
    require("models.sequence").set_undo_cursor_for_project(project_id, 0)
end

-- ---------------------------------------------------------------------------
-- Per-format import descriptors. open_project owns the convert lifecycle
-- (wipe → init DB → create project → import → tab state → provenance →
-- WAL checkpoint); each importer module owns format-knowledge (parse,
-- derive settings, entity creation, tab extraction). The descriptor
-- table is the seam — every format-specific decision the lifecycle
-- needs is one entry. Adding a new format (e.g. FCP7) means adding an
-- entry here, not duplicating the lifecycle.
-- ---------------------------------------------------------------------------

local function drp_parse(importer, path, progress)
    return importer.parse_drp_file(path, progress)
end

local function drp_derive_settings(importer, parse_result, opts)
    -- Audio rate resolution: explicit caller arg, else majority vote
    -- across parsed media. nil propagates → import_into_project asserts
    -- (Resolve has no project-wide audio default to invent).
    local audio_rate = (opts and opts.audio_sample_rate)
        or importer.pick_majority_audio_sample_rate(parse_result)
    return importer.derive_project_settings(parse_result, audio_rate)
end

local function prproj_parse(importer, path, progress)
    return importer.parse_prproj_file(path, progress)
end

local function prproj_derive_settings(importer, parse_result, _opts)
    return importer.derive_project_settings(parse_result)
end

local IMPORT_FORMATS = {
    drp = {
        format_label            = "DaVinci Resolve",
        importer_module         = "importers.drp_importer",
        provenance_command_type = "ImportResolveProject",
        provenance_path_key     = "drp_path",
        parse                   = drp_parse,
        derive_settings         = drp_derive_settings,
    },
    prproj = {
        format_label            = "Premiere Pro",
        importer_module         = "importers.prproj_importer",
        provenance_command_type = "ImportPremiereProject",
        provenance_path_key     = "prproj_path",
        parse                   = prproj_parse,
        derive_settings         = prproj_derive_settings,
    },
}

--- Convert a source project file into a fresh .jvp via the format
--- descriptor. Returns ``true`` on success, ``false, "Cancelled"`` on
--- user cancel; raises on every other failure mode (parse / DB / save).
--- Owns the DB lifecycle (wipe + init + project record + WAL
--- checkpoint); the descriptor's importer owns format knowledge.
local function convert_to_jvp(descriptor, src_path, jvp_path, progress_cb, opts)
    assert(type(descriptor) == "table" and descriptor.importer_module,
        "convert_to_jvp: descriptor with importer_module required")
    assert(src_path and src_path ~= "", "convert_to_jvp: src_path required")
    assert(jvp_path and jvp_path ~= "", "convert_to_jvp: jvp_path required")

    local importer = require(descriptor.importer_module)
    local function report(pct, text) report_progress(progress_cb, pct, text) end

    log.event("Converting %s -> %s", src_path, jvp_path)

    local convert_ok, convert_err = pcall(function()
        report(5, "Parsing project file…")
        local parse_result = descriptor.parse(
            importer, src_path, remap_progress(progress_cb, 5, 25))
        assert(parse_result.success, string.format(
            "Failed to parse %s file: %s",
            descriptor.format_label, tostring(parse_result.error)))

        local settings = descriptor.derive_settings(importer, parse_result, opts)

        report(30, "Creating project database…")
        wipe_destination(jvp_path)
        require("core.database").init(jvp_path)
        local project = create_project_record(parse_result, settings)

        report(40, "Importing media…")
        local import_result = importer.import_into_project(project.id, parse_result, {
            project_settings = settings,
            progress_cb      = remap_progress(progress_cb, 40, 50),
        })

        report(95, "Setting active timeline…")
        local tabs = importer.extract_tab_state(parse_result, import_result)
        if tabs then persist_tab_state(project.id, tabs) end

        report(98, "Recording provenance…")
        record_import_provenance(project.id, descriptor.provenance_command_type,
            src_path, parse_result.project.name, descriptor.provenance_path_key)

        -- Self-contained-file contract: cross-process consumers (smoke
        -- runner moves only the .jvp; backup / sync tools may skip
        -- sidecars) would otherwise lose every write made since the
        -- last auto-checkpoint — most visibly tab state, which causes
        -- the editor to fall back to an arbitrary sequence on next open.
        local checkpoint_ok, checkpoint_err = require("core.database").checkpoint_wal()
        assert(checkpoint_ok, string.format(
            "convert_to_jvp: WAL checkpoint failed — %s", tostring(checkpoint_err)))

        report(100, "Done")
    end)

    if convert_ok then return true end
    if type(convert_err) == "table" and convert_err.cancelled then
        return false, "Cancelled"
    end
    error(convert_err)
end

-- Named per-format entry points. These exist as the stable test/API
-- surface (many binding tests call them directly; the smoke runner's
-- build_template.py embeds the .drp variant). The body lives in
-- convert_to_jvp; these select the descriptor.
local function convert_drp_to_jvp(drp_path, jvp_path, progress_cb, opts)
    return convert_to_jvp(IMPORT_FORMATS.drp, drp_path, jvp_path, progress_cb, opts)
end

local function convert_prproj_to_jvp(prproj_path, jvp_path, progress_cb, opts)
    return convert_to_jvp(IMPORT_FORMATS.prproj, prproj_path, jvp_path, progress_cb, opts)
end

M._convert_drp_to_jvp    = convert_drp_to_jvp     -- exported for tests
M._convert_prproj_to_jvp = convert_prproj_to_jvp  -- exported for tests

-- Route a non-native format through the user-facing conversion dialog:
-- show metadata + destination chooser, then drive the lifecycle via
-- convert_to_jvp. Returns the resolved .jvp path or nil on cancel.
-- The convert lifecycle lives in this module — importers are format-
-- knowledge only; lifecycle (DB swap + signal cascade) belongs to
-- OpenProject.
local FILE_FILTER_JVP = "JVE Project Files (*.jvp)"

local function route_through_conversion_dialog(descriptor, src_path, parent_widget)
    local importer = require(descriptor.importer_module)
    local conversion_dialog = require("ui.conversion_dialog")

    local meta, meta_err = importer.quick_metadata(src_path)
    if not meta then
        error(string.format("Failed to read %s metadata: %s",
            descriptor.format_label, tostring(meta_err)))
    end

    return conversion_dialog.show({
        source_path  = src_path,
        format_label = descriptor.format_label,
        project_name = meta.name,
        default_ext  = ".jvp",
        file_filter  = FILE_FILTER_JVP,
        convert_fn   = function(s, d, pcb, opts)
            return convert_to_jvp(descriptor, s, d, pcb, opts)
        end,
        parent       = parent_widget,
    })
end

--- Resolve project format: detect .drp/.jvp/.prproj, convert if needed.
-- @param path string: path to project file
-- @param parent_widget userdata|nil: parent widget for conversion dialog
-- @return string|nil: resolved .jvp path, or nil if user cancelled
-- @raises error on unknown format or conversion failure
function M.resolve_format(path, parent_widget)
    local format = detect_project_format(path)
    if format == "jvp" then return path end

    local descriptor = IMPORT_FORMATS[format]
    if descriptor then
        return route_through_conversion_dialog(descriptor, path, parent_widget)
    end

    if format == "resolve_db" then
        error("Resolve database peer mode not yet implemented")
    end

    error("Unknown project format: " .. tostring(path))
end

-- Schema for OpenProject command
local SPEC = {
    args = {
        interactive = { kind = "boolean" },  -- If true, show file picker dialog
        project_path = {},  -- Path to project file (or gathered from dialog)
    },
    no_persist = true,  -- Opening a project is not a typical undoable command
    no_project_context = true,  -- Doesn't require active project (it OPENS a project)
}

--- Post-open wiring shared by OpenProject and NewProject: emits signals,
--- reinitializes command_manager, restores layout, loads the active
--- sequence into the timeline.
--- @param project table: loaded Project (required)
--- @param sequence table|nil: Sequence object, or nil for the
---        no-active-sequence state (feature 010: project has no saved tab info)
--- @param project_path string: filesystem path of the .jvp
--- @return table {success=true, project_id, sequence_id}
function M.post_open_init(project, sequence, project_path)
    assert(project and project.id and project.id ~= "",
        "open_project.post_open_init: project with id required")
    assert(project_path and project_path ~= "",
        "open_project.post_open_init: project_path required")
    if sequence then
        assert(sequence.id and sequence.project_id == project.id,
            "open_project.post_open_init: sequence must belong to project")
    end

    local project_id = project.id
    local sequence_id = sequence and sequence.id

    local ui_state = require("ui.ui_state")
    local timeline_panel = ui_state.get_timeline_panel()
    local database = require("core.database")
    local panel_manager = require("ui.panel_manager")

    -- Snapshot outgoing project's full layout before switching
    local layout_snapshot = nil
    if timeline_panel and timeline_panel.snapshot_layout then
        layout_snapshot = timeline_panel.snapshot_layout()
    end
    local outgoing_splitter_sizes = panel_manager.get_persistable_sizes()
    local main_window = ui_state.get_main_window()
    local outgoing_geometry = nil
    if main_window and qt_constants.PROPERTIES.GET_GEOMETRY then
        local x, y, w, h = qt_constants.PROPERTIES.GET_GEOMETRY(main_window)
        if w > 100 and h > 100 then
            outgoing_geometry = { x = x, y = y, width = w, height = h }
        end
    end

    -- Notify all interested modules of project change (stops playback, clears caches)
    local Signals = require("core.signals")
    Signals.emit("project_changed", project_id)

    -- Re-initialize command manager with new database. Branch on the active
    -- sequence: a project with no saved tab info opens in the no-active-
    -- sequence state (feature 010).
    local command_manager = require("core.command_manager")
    if sequence_id then
        command_manager.init(sequence_id, project_id)
    else
        command_manager.init_project_only(project_id)
    end

    -- Get UI references
    local project_browser = ui_state.get_project_browser()

    -- Restore layout: use new project's saved state, or inherit from outgoing
    local new_project_id = project_id
    local saved_splitters = database.get_project_setting(new_project_id, "splitter_sizes")
    if not saved_splitters and outgoing_splitter_sizes then
        -- New project has no layout → inherit from outgoing and persist
        database.set_project_setting(new_project_id, "splitter_sizes", outgoing_splitter_sizes)
        saved_splitters = outgoing_splitter_sizes
    end
    if saved_splitters then
        panel_manager.restore_sizes(saved_splitters)
    end

    local saved_geo = database.get_project_setting(new_project_id, "window_geometry")
    if not saved_geo and outgoing_geometry then
        database.set_project_setting(new_project_id, "window_geometry", outgoing_geometry)
    end

    -- Load timeline only when a sequence is active. With no sequence, the
    -- timeline panel stays blank (feature 010).
    if sequence_id and timeline_panel and timeline_panel.load_sequence then
        timeline_panel.load_sequence(sequence_id)
    end

    -- Inherit timeline scroll/splitter from outgoing project if new has defaults
    if layout_snapshot and timeline_panel and timeline_panel.apply_layout_if_default then
        timeline_panel.apply_layout_if_default(layout_snapshot)
    end

    -- Refresh project browser (set project_id first to avoid stale cache)
    if project_browser then
        if project_browser.set_project_id then
            project_browser.set_project_id(project_id)
        end
        if project_browser.refresh then
            project_browser.refresh()
        end
    end

    if sequence_id and project_browser and project_browser.focus_sequence then
        project_browser.focus_sequence(sequence_id)
    end

    -- Set window title
    if project.name and project.name ~= "" then
        if main_window and qt_constants and qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_TITLE then
            qt_constants.PROPERTIES.SET_TITLE(main_window, project.name)
        end
    end

    -- Persist last-opened project path for startup. HOME is hard-required —
    -- the same function asserts it for the interactive path (rule 1.14).
    local home = assert(os.getenv("HOME"),
        "open_project.post_open_init: HOME env var required")
    local jve_dir = home .. "/.jve"
    local ok, err = qt_fs_mkdir_p(jve_dir)
    assert(ok, "open_project: mkdir " .. jve_dir .. " failed: " .. tostring(err))
    local last_path_file = home .. "/.jve/last_project_path"
    local f, open_err = io.open(last_path_file, "w")
    assert(f, string.format(
        "open_project: cannot write %s: %s", last_path_file, tostring(open_err)))
    f:write(project_path)
    f:close()

    -- Add to recent projects list
    local display_name = (project and project.name) or "Untitled"
    recent_projects.add(display_name, project_path)

    log.event("Opened project: %s (sequence: %s)",
        project.id, sequence and sequence.id or "none")

    -- Initialize peak cache and queue waveform generation for all audio media
    local peak_cache = require("core.media.peak_cache")
    peak_cache.init_for_project(project.id)

    return {
        success    = true,
        project_id = project.id,
        sequence_id = sequence and sequence.id or nil,
    }
end

function M.register(executors, undoers, db, set_last_error)

    -- =========================================================================
    -- OpenProject: Open project with optional interactive dialog
    -- =========================================================================
    executors["OpenProject"] = function(command)
        local args = command:get_all_parameters()
        local project_path = args.project_path

        -- If interactive mode or no project path provided, show dialog
        if args.interactive or not project_path or project_path == "" then
            log.event("OpenProject: Showing file picker dialog")

            -- Get UI references for dialog
            local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
            if not ui_state_ok then
                return { success = false, error_message = "UI state not initialized" }
            end

            local main_window = ui_state.get_main_window()
            if not main_window then
                return { success = false, error_message = "Main window not initialized" }
            end

            -- Show file picker dialog (accepts .jvp native, .drp Resolve archive)
            local home = os.getenv("HOME")
            assert(home and home ~= "", "open_project: HOME must be set")
            local default_dir = home .. "/Documents/JVE Projects"
            project_path = file_browser.open_file(
                "open_project", main_window,
                "Open Project",
                "All Project Files (*.jvp *.drp);;JVE Projects (*.jvp);;Resolve Archives (*.drp);;All Files (*)",
                default_dir
            )

            if not project_path or project_path == "" then
                log.event("OpenProject: User cancelled file picker")
                return { success = true, cancelled = true }
            end

            -- Store the gathered project path
            command:set_parameter("project_path", project_path)
        end

        log.event("Opening project: %s", tostring(project_path))

        -- Detect format and convert if needed (.drp → .jvp)
        local ui_state_ok2, ui_state2 = pcall(require, "ui.ui_state")
        local resolve_parent = ui_state_ok2 and ui_state2.get_main_window() or nil

        local resolved_ok, resolved_path = pcall(M.resolve_format, project_path, resolve_parent)
        if not resolved_ok then
            return { success = false, error_message = tostring(resolved_path) }
        end
        if not resolved_path then
            log.event("OpenProject: User cancelled format resolution")
            return { success = true, cancelled = true }
        end
        project_path = resolved_path

        -- Get main_window for error dialogs
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        local main_window = ui_state_ok and ui_state.get_main_window() or nil

        -- Open .jvp database
        local database = require("core.database")
        local opened = project_open.open_project_database_or_prompt_cleanup(
            database, qt_constants, project_path, main_window
        )

        if not opened then
            if main_window and qt_constants and qt_constants.DIALOG then
                qt_constants.DIALOG.SHOW_CONFIRM({
                    parent = main_window,
                    title = "Open Project Failed",
                    message = "Failed to open project database:\n" .. tostring(project_path),
                    confirm_text = "OK",
                    cancel_text = "Cancel",
                    icon = "warning",
                    default_button = "confirm"
                })
            end
            return { success = false, error_message = "Failed to open project database" }
        end

        -- Resolve the initial active sequence from saved tab state. nil means
        -- the project opens in the no-active-sequence state (feature 010).
        local Sequence = require("models.sequence")
        local Project = require("models.project")
        local project_id = database.get_current_project_id()
        local project = Project.load(project_id)
        if not project then
            return { success = false, error_message = "Project row not found after open" }
        end

        local sequence = Sequence.resolve_initial_for_project(project_id)
        -- sequence may be nil — post_open_init accepts nil and opens blank.

        local result = M.post_open_init(project, sequence, project_path)
        return result
    end

    -- No undoer - opening a project is not undoable

    return {
        ["OpenProject"] = {
            executor = executors["OpenProject"],
            spec = SPEC,
        },
    }
end

return M
