--- NewProject command: interactive dialog for creating projects from templates
--
-- Responsibilities:
-- - Show dialog with name, location, and template selection
-- - Create .jvp from template via project_templates
-- - Open the new project via open_project.post_open_init
--
-- Non-goals:
-- - Undo support (creating a project is an application-level action)
-- - Template editing
--
-- Invariants:
-- - Requires user to provide a non-empty name
-- - Asserts destination doesn't already exist
-- - Uses open_project.post_open_init for uniform post-open wiring
--
-- Size: ~150 LOC
-- Volatility: low
--
-- @file new_project.lua
local M = {}
local logger = require("core.logger")
local project_templates = require("core.project_templates")
local file_browser = require("core.file_browser")

-- Schema for NewProject command
local SPEC = {
    args = {},
    no_persist = true,
    no_project_context = true,
}

--- Show the New Project dialog (blocking modal).
-- @param parent_window widget|nil: Qt parent widget
-- @return table|nil: {project_path, project_name} or nil if cancelled
function M.show_dialog(parent_window)
    local qt = require("core.qt_constants")
    local templates = project_templates.TEMPLATES

    -- Dialog state
    local dialog_result = nil

    local dialog = qt.DIALOG.CREATE("New Project", 500, 280)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- -----------------------------------------------------------------------
    -- Name row
    -- -----------------------------------------------------------------------
    local name_layout = qt.LAYOUT.CREATE_HBOX()
    local name_label = qt.WIDGET.CREATE_LABEL("Name:")
    local name_input = qt.WIDGET.CREATE_LINE_EDIT("")
    qt.LAYOUT.ADD_WIDGET(name_layout, name_label)
    qt.LAYOUT.ADD_WIDGET(name_layout, name_input)
    qt.LAYOUT.ADD_LAYOUT(main_layout, name_layout)

    -- -----------------------------------------------------------------------
    -- Location row
    -- -----------------------------------------------------------------------
    local home = os.getenv("HOME") or ""
    local default_location = home ~= "" and (home .. "/Documents/JVE Projects") or ""

    local loc_layout = qt.LAYOUT.CREATE_HBOX()
    local loc_label = qt.WIDGET.CREATE_LABEL("Location:")
    local loc_input = qt.WIDGET.CREATE_LINE_EDIT("")
    qt.PROPERTIES.SET_TEXT(loc_input, default_location)
    local browse_btn = qt.WIDGET.CREATE_BUTTON("Browse...")
    qt.LAYOUT.ADD_WIDGET(loc_layout, loc_label)
    qt.LAYOUT.ADD_WIDGET(loc_layout, loc_input)
    qt.LAYOUT.ADD_WIDGET(loc_layout, browse_btn)
    qt.LAYOUT.ADD_LAYOUT(main_layout, loc_layout)

    -- Browse handler
    local browse_handler = "__new_project_browse"
    _G[browse_handler] = function()
        local dir = file_browser.open_directory(
            "new_project_location", parent_window or dialog,
            "Choose Project Location", default_location)
        if dir and dir ~= "" then
            qt.PROPERTIES.SET_TEXT(loc_input, dir)
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(browse_btn, browse_handler)

    -- -----------------------------------------------------------------------
    -- Template row
    -- -----------------------------------------------------------------------
    local tmpl_layout = qt.LAYOUT.CREATE_HBOX()
    local tmpl_label = qt.WIDGET.CREATE_LABEL("Template:")
    local tmpl_combo = qt.WIDGET.CREATE_COMBOBOX()
    for _, t in ipairs(templates) do
        qt.PROPERTIES.ADD_COMBOBOX_ITEM(tmpl_combo, t.name)
    end
    qt.LAYOUT.ADD_WIDGET(tmpl_layout, tmpl_label)
    qt.LAYOUT.ADD_WIDGET(tmpl_layout, tmpl_combo)
    qt.LAYOUT.ADD_LAYOUT(main_layout, tmpl_layout)

    -- Template info label (static: shows first template info by default)
    local info_label = qt.WIDGET.CREATE_LABEL(project_templates.format_info(templates[1]))
    qt.LAYOUT.ADD_WIDGET(main_layout, info_label)

    -- -----------------------------------------------------------------------
    -- Error label (hidden by default, shown on validation failure)
    -- -----------------------------------------------------------------------
    local error_label = qt.WIDGET.CREATE_LABEL("")
    qt.PROPERTIES.SET_STYLE(error_label, "color: #ff6666;")
    qt.LAYOUT.ADD_WIDGET(main_layout, error_label)

    -- -----------------------------------------------------------------------
    -- Button row
    -- -----------------------------------------------------------------------
    qt.LAYOUT.ADD_STRETCH(main_layout)
    local btn_layout = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_STRETCH(btn_layout)

    local cancel_btn = qt.WIDGET.CREATE_BUTTON("Cancel")
    local create_btn = qt.WIDGET.CREATE_BUTTON("Create")

    local cancel_handler = "__new_project_cancel"
    _G[cancel_handler] = function()
        dialog_result = nil
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(cancel_btn, cancel_handler)

    local create_handler = "__new_project_create"
    _G[create_handler] = function()
        -- Read inputs
        local name = qt.PROPERTIES.GET_TEXT(name_input)
        local location = qt.PROPERTIES.GET_TEXT(loc_input)
        local tmpl_index = qt.PROPERTIES.GET_COMBOBOX_CURRENT_INDEX(tmpl_combo)

        -- Validate name
        if not name or name:match("^%s*$") then
            qt.PROPERTIES.SET_TEXT(error_label, "Project name is required")
            return
        end
        if name:find("/") then
            qt.PROPERTIES.SET_TEXT(error_label, "Project name cannot contain '/'")
            return
        end

        -- Validate location
        if not location or location:match("^%s*$") then
            qt.PROPERTIES.SET_TEXT(error_label, "Location is required")
            return
        end

        -- Resolve template (0-indexed from C++)
        local template = templates[(tmpl_index or 0) + 1]
        if not template then
            qt.PROPERTIES.SET_TEXT(error_label, "Invalid template selection")
            return
        end

        -- Build dest path
        local dest_path = location .. "/" .. name .. ".jvp"

        -- Check if already exists
        local check = io.open(dest_path, "rb")
        if check then
            check:close()
            qt.PROPERTIES.SET_TEXT(error_label, "Project already exists: " .. name .. ".jvp")
            return
        end

        -- Ensure location directory exists
        os.execute(string.format('mkdir -p %q', location))

        -- Create from template
        local ok, result_or_err = pcall(
            project_templates.create_project_from_template,
            template, name, dest_path)

        if not ok then
            qt.PROPERTIES.SET_TEXT(error_label, "Failed: " .. tostring(result_or_err))
            return
        end

        dialog_result = {
            project_path = dest_path,
            project_name = name,
        }
        qt.DIALOG.CLOSE(dialog, true)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(create_btn, create_handler)

    qt.LAYOUT.ADD_WIDGET(btn_layout, cancel_btn)
    qt.LAYOUT.ADD_SPACING(btn_layout, 8)
    qt.LAYOUT.ADD_WIDGET(btn_layout, create_btn)
    qt.LAYOUT.ADD_LAYOUT(main_layout, btn_layout)

    qt.DIALOG.SET_LAYOUT(dialog, main_layout)

    -- Show (blocking)
    logger.info("new_project", "Showing New Project dialog")
    qt.DIALOG.SHOW(dialog)

    -- Cleanup globals
    _G[browse_handler] = nil
    _G[cancel_handler] = nil
    _G[create_handler] = nil

    return dialog_result
end

function M.register(executors, undoers, db, set_last_error)

    -- =========================================================================
    -- NewProject: Show dialog, create project from template, open it
    -- =========================================================================
    executors["NewProject"] = function(_command)
        -- Get parent window
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        local main_window = ui_state_ok and ui_state.get_main_window() or nil

        local result = M.show_dialog(main_window)
        if not result then
            logger.debug("new_project", "NewProject: User cancelled")
            return { success = true, cancelled = true }
        end

        -- Open the new project via normal flow
        local open_project = require("core.commands.open_project")
        local project_open = require("core.project_open")
        local database = require("core.database")

        local opened = project_open.open_project_database_or_prompt_cleanup(
            database, qt_constants, result.project_path, main_window)

        if not opened then
            return { success = false, error_message = "Failed to open new project database" }
        end

        -- Find sequence in new project
        local Sequence = require("models.sequence")
        local sequence = Sequence.find_most_recent()

        if not sequence then
            return { success = false, error_message = "No sequences in new project" }
        end

        return open_project.post_open_init(sequence, result.project_path)
    end

    return {
        ["NewProject"] = {
            executor = executors["NewProject"],
            spec = SPEC,
        },
    }
end

return M
