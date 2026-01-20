--- Open Project Command - Interactive dialog and non-interactive project loading
--
-- Responsibilities:
-- - OpenProject: Shows file picker when interactive=true, opens project database
--
-- Non-goals:
-- - Undo support (opening a project is an application-level action, not undoable)
-- - Creating new projects (see NewProject command)
--
-- Invariants:
-- - Requires project_path (or gathered from dialog)
-- - After opening, command_manager is re-initialized with new database
--
-- Size: ~150 LOC
-- Volatility: low
--
-- @file open_project.lua
local M = {}
local logger = require("core.logger")
local project_open = require("core.project_open")

-- Schema for OpenProject command
local SPEC = {
    args = {
        interactive = { kind = "boolean" },  -- If true, show file picker dialog
        project_path = {},  -- Path to project file (or gathered from dialog)
    },
    no_persist = true,  -- Opening a project is not a typical undoable command
}

function M.register(executors, undoers, db, set_last_error)

    -- =========================================================================
    -- OpenProject: Open project with optional interactive dialog
    -- =========================================================================
    executors["OpenProject"] = function(command)
        local args = command:get_all_parameters()
        local project_path = args.project_path

        -- If interactive mode or no project path provided, show dialog
        if args.interactive or not project_path or project_path == "" then
            logger.info("open_project", "OpenProject: Showing file picker dialog")

            -- Get UI references for dialog
            local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
            if not ui_state_ok then
                return { success = false, error_message = "UI state not initialized" }
            end

            local main_window = ui_state.get_main_window()
            if not main_window then
                return { success = false, error_message = "Main window not initialized" }
            end

            -- Show file picker dialog
            local home = os.getenv("HOME") or ""
            local default_dir = home ~= "" and (home .. "/Documents/JVE Projects") or ""
            project_path = qt_constants.FILE_DIALOG.OPEN_FILE(
                main_window,
                "Open Project",
                "JVE Project Files (*.jvp);;All Files (*)",
                default_dir
            )

            if not project_path or project_path == "" then
                logger.debug("open_project", "OpenProject: User cancelled file picker")
                return { success = true, cancelled = true }
            end

            -- Store the gathered project path
            command:set_parameter("project_path", project_path)
        end

        logger.info("open_project", "Opening project: " .. tostring(project_path))

        -- Get UI references
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        local main_window = ui_state_ok and ui_state.get_main_window() or nil
        local project_browser = ui_state_ok and ui_state.get_project_browser() or nil
        local timeline_panel = ui_state_ok and ui_state.get_timeline_panel() or nil

        -- Open database
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

        local db_conn = database.get_connection()
        if not db_conn then
            return { success = false, error_message = "Database connection is nil after open" }
        end

        -- Find most recent sequence
        local sequence_id, project_id
        local stmt = db_conn:prepare([[
            SELECT id, project_id
            FROM sequences
            ORDER BY modified_at DESC, created_at DESC, id ASC
            LIMIT 1
        ]])

        if not stmt then
            return { success = false, error_message = "Failed to prepare sequence query" }
        end

        local ok = stmt:exec() and stmt:next()
        if ok then
            sequence_id = stmt:value(0)
            project_id = stmt:value(1)
        end
        stmt:finalize()

        if not sequence_id or sequence_id == "" then
            return { success = false, error_message = "No sequences found in project" }
        end

        if not project_id or project_id == "" then
            return { success = false, error_message = "Sequence missing project_id" }
        end

        -- Re-initialize command manager with new database
        local command_manager = require("core.command_manager")
        command_manager.init(db_conn, sequence_id, project_id)

        -- Load timeline
        if timeline_panel and timeline_panel.load_sequence then
            timeline_panel.load_sequence(sequence_id)
        end

        -- Refresh project browser
        if project_browser and project_browser.refresh then
            project_browser.refresh()
        end

        if project_browser and project_browser.focus_sequence then
            project_browser.focus_sequence(sequence_id)
        end

        -- Set window title
        local Project = require("models.project")
        local project = Project.load(project_id)
        if project and project.name and project.name ~= "" then
            if main_window and qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_TITLE then
                qt_constants.PROPERTIES.SET_TITLE(main_window, project.name)
            end
        end

        logger.info("open_project", string.format("Opened project: %s (sequence: %s)", project_id, sequence_id))

        return { success = true, project_id = project_id, sequence_id = sequence_id }
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
