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
    elseif ext == "db" or ext == "resolve" then
        return "resolve_db"
    else
        return "unknown"
    end
end

--- Resolve project format: detect .drp/.jvp, convert if needed.
-- @param path string: path to project file (.jvp or .drp)
-- @param parent_widget userdata|nil: parent widget for conversion dialog
-- @return string|nil: resolved .jvp path, or nil if user cancelled
-- @raises error on unknown format or conversion failure
function M.resolve_format(path, parent_widget)
    local format = detect_project_format(path)
    if format == "jvp" then return path end

    if format == "drp" then
        local drp_importer = require("importers.drp_importer")
        local conversion_dialog = require("ui.conversion_dialog")

        -- Quick metadata for dialog (no full parse)
        local meta, meta_err = drp_importer.quick_metadata(path)
        if not meta then error("Failed to read DRP metadata: " .. tostring(meta_err)) end

        local dest_path = conversion_dialog.show({
            source_path = path,
            format_label = "DaVinci Resolve",
            project_name = meta.name,
            default_ext = ".jvp",
            file_filter = "JVE Project Files (*.jvp)",
            convert_fn = drp_importer.convert,
            parent = parent_widget,
        })

        if not dest_path then return nil end  -- cancelled
        return dest_path
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

--- Post-open initialization: wires up UI, emits signals, persists state.
-- Shared by OpenProject and NewProject executors.
-- @param sequence table: loaded Sequence object (must have .id and .project_id)
-- @param project_path string: absolute path to the .jvp file
-- @return table: {success=true, project_id=..., sequence_id=...}
function M.post_open_init(sequence, project_path)
    assert(sequence and sequence.id and sequence.project_id,
        "open_project.post_open_init: valid sequence required")
    assert(project_path and project_path ~= "",
        "open_project.post_open_init: project_path required")

    -- Notify all interested modules of project change (stops playback, clears caches)
    local Signals = require("core.signals")
    Signals.emit("project_changed", sequence.project_id)

    -- Re-initialize command manager with new database
    local command_manager = require("core.command_manager")
    command_manager.init(sequence.id, sequence.project_id)

    -- Get UI references
    local ui_state = require("ui.ui_state")
    local main_window = ui_state.get_main_window()
    local project_browser = ui_state.get_project_browser()
    local timeline_panel = ui_state.get_timeline_panel()

    -- Load timeline
    if timeline_panel and timeline_panel.load_sequence then
        timeline_panel.load_sequence(sequence.id)
    end

    -- Refresh project browser (set project_id first to avoid stale cache)
    if project_browser then
        if project_browser.set_project_id then
            project_browser.set_project_id(sequence.project_id)
        end
        if project_browser.refresh then
            project_browser.refresh()
        end
    end

    if project_browser and project_browser.focus_sequence then
        project_browser.focus_sequence(sequence.id)
    end

    -- Set window title
    local Project = require("models.project")
    local project = Project.load(sequence.project_id)
    assert(project, string.format(
        "post_open_init: Project.load(%s) returned nil after successful open",
        tostring(sequence.project_id)))
    if project.name and project.name ~= "" then
        if main_window and qt_constants and qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_TITLE then
            qt_constants.PROPERTIES.SET_TITLE(main_window, project.name)
        end
    end

    -- Persist last-opened project path for startup
    local home = os.getenv("HOME")
    if home then
        os.execute('mkdir -p "' .. home .. '/.jve"')
        local f = io.open(home .. "/.jve/last_project_path", "w")
        if f then
            f:write(project_path)
            f:close()
        end
    end

    -- Add to recent projects list
    local display_name = (project and project.name) or "Untitled"
    recent_projects.add(display_name, project_path)

    log.event("Opened project: %s (sequence: %s)", sequence.project_id, sequence.id)

    return { success = true, project_id = sequence.project_id, sequence_id = sequence.id }
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
            local home = os.getenv("HOME") or ""
            local default_dir = home ~= "" and (home .. "/Documents/JVE Projects") or ""
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

        -- Find best sequence: last-open if available, else most recent
        local Sequence = require("models.sequence")
        local sequence
        local last_id = database.get_project_setting(
            database.get_current_project_id(), "last_open_sequence_id")
        if last_id and last_id ~= "" then
            sequence = Sequence.load(last_id)
        end
        if not sequence then
            sequence = Sequence.find_most_recent()
        end

        if not sequence then
            return { success = false, error_message = "No sequences found in project" }
        end

        if not sequence.project_id or sequence.project_id == "" then
            return { success = false, error_message = "Sequence missing project_id" }
        end

        local result = M.post_open_init(sequence, project_path)
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
