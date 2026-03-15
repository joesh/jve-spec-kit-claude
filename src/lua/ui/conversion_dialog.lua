--- conversion_dialog: reusable modal dialog for converting foreign project formats
--
-- Responsibilities:
-- - Display source path, project name, save-as path with Browse
-- - Progress bar + status text during conversion (pumps PROCESS_EVENTS)
-- - Scrolling log area for warnings/errors during conversion
-- - Save Log button when log has content
-- - Retry on error (re-enable Browse + Convert)
--
-- Non-goals:
-- - Format-specific logic (callers provide convert_fn + metadata)
-- - Opening the converted project (caller handles that)
--
-- Invariants:
-- - config.convert_fn(source, dest, progress_cb) is the single conversion entry
-- - progress_cb pumps Qt events — UI stays responsive without threading
-- - Returns dest_path on success, nil on cancel
--
-- Size: ~200 LOC
-- Volatility: low
--
-- @file conversion_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")

--- Read the directory from ~/.jve/last_project_path for default save location.
-- @return string: directory path, or ~/Documents/JVE Projects as fallback
local function get_default_dir()
    local home = os.getenv("HOME") or ""
    if home == "" then return "" end

    local f = io.open(home .. "/.jve/last_project_path", "r")
    if f then
        local last_path = f:read("*a"):match("^%s*(.-)%s*$")
        f:close()
        if last_path and last_path ~= "" then
            local dir = last_path:match("^(.+)/[^/]+$")
            if dir then return dir end
        end
    end

    return home .. "/Documents/JVE Projects"
end

--- Show a conversion dialog and run the conversion.
-- @param config table:
--   source_path     string   — path to source file
--   format_label    string   — e.g. "DaVinci Resolve" (used in title + labels)
--   project_name    string   — display name extracted from source
--   default_ext     string   — e.g. ".jvp"
--   file_filter     string   — e.g. "JVE Project Files (*.jvp)"
--   convert_fn      function(source_path, dest_path, progress_cb) → ok, err
--   parent          widget|nil
-- @return string|nil — destination path on success, nil on cancel/failure
function M.show(config)
    assert(config, "conversion_dialog.show: config required")
    assert(config.source_path and config.source_path ~= "",
        "conversion_dialog.show: source_path required")
    assert(config.format_label and config.format_label ~= "",
        "conversion_dialog.show: format_label required")
    assert(config.project_name and config.project_name ~= "",
        "conversion_dialog.show: project_name required")
    assert(config.convert_fn, "conversion_dialog.show: convert_fn required")

    local qt = require("core.qt_constants")
    local file_browser = require("core.file_browser")

    local default_ext = config.default_ext or ".jvp"
    local file_filter = config.file_filter or "JVE Project Files (*.jvp)"
    local default_dir = get_default_dir()
    local default_name = config.project_name .. default_ext

    -- State
    local dest_path = default_dir .. "/" .. default_name
    local result_path = nil  -- set on successful conversion
    -- log_lines now managed by progress_panel
    local globals = {}       -- _G handler names for cleanup

    -- Create dialog
    local dialog = qt.DIALOG.CREATE(
        "Convert " .. config.format_label .. " Project", 550, 380)

    -- -----------------------------------------------------------------------
    -- Widget tree
    -- -----------------------------------------------------------------------
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- Title
    local title_label = qt.WIDGET.CREATE_LABEL(
        "Convert " .. config.format_label .. " Project")
    qt.LAYOUT.ADD_WIDGET(main_layout, title_label)
    qt.LAYOUT.ADD_SPACING(main_layout, 8)

    -- Source row
    local source_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(source_row, qt.WIDGET.CREATE_LABEL("Source:"))
    local source_label = qt.WIDGET.CREATE_LABEL(config.source_path)
    qt.LAYOUT.ADD_WIDGET(source_row, source_label)
    qt.LAYOUT.ADD_LAYOUT(main_layout, source_row)

    -- Project name row
    local name_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(name_row, qt.WIDGET.CREATE_LABEL("Project:"))
    qt.LAYOUT.ADD_WIDGET(name_row, qt.WIDGET.CREATE_LABEL(config.project_name))
    qt.LAYOUT.ADD_LAYOUT(main_layout, name_row)
    qt.LAYOUT.ADD_SPACING(main_layout, 4)

    -- Save-as row
    local save_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(save_row, qt.WIDGET.CREATE_LABEL("Save as:"))
    local save_edit = qt.WIDGET.CREATE_LINE_EDIT(dest_path)
    qt.CONTROL.SET_LINE_EDIT_READ_ONLY(save_edit, true)
    qt.LAYOUT.ADD_WIDGET(save_row, save_edit)
    local browse_btn = qt.WIDGET.CREATE_BUTTON("Browse…")
    qt.LAYOUT.ADD_WIDGET(save_row, browse_btn)
    qt.LAYOUT.ADD_LAYOUT(main_layout, save_row)
    qt.LAYOUT.ADD_SPACING(main_layout, 8)

    -- Progress panel (shared component)
    local progress_panel = require("ui.progress_panel")
    local progress = progress_panel.create(main_layout, {log_height = 100, width = 500})

    -- Error label (hidden initially)
    local error_label = qt.WIDGET.CREATE_LABEL("")
    qt.DISPLAY.SET_VISIBLE(error_label, false)
    qt.LAYOUT.ADD_WIDGET(main_layout, error_label)

    qt.LAYOUT.ADD_STRETCH(main_layout)

    -- Button row
    local btn_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_STRETCH(btn_row)

    local save_log_btn = qt.WIDGET.CREATE_BUTTON("Save Log…")
    qt.DISPLAY.SET_VISIBLE(save_log_btn, false)
    qt.LAYOUT.ADD_WIDGET(btn_row, save_log_btn)

    local convert_btn = qt.WIDGET.CREATE_BUTTON("Convert")
    qt.LAYOUT.ADD_WIDGET(btn_row, convert_btn)

    local cancel_btn = qt.WIDGET.CREATE_BUTTON("Cancel")
    qt.LAYOUT.ADD_WIDGET(btn_row, cancel_btn)

    qt.LAYOUT.ADD_LAYOUT(main_layout, btn_row)

    -- -----------------------------------------------------------------------
    -- Helpers
    -- -----------------------------------------------------------------------

    local function set_converting(active)
        qt.CONTROL.SET_ENABLED(browse_btn, not active)
        qt.CONTROL.SET_ENABLED(convert_btn, not active)
        if active then progress.show() else progress.hide() end
    end

    -- -----------------------------------------------------------------------
    -- Handlers
    -- -----------------------------------------------------------------------

    -- Browse
    local browse_name = "__conversion_dialog_browse"
    _G[browse_name] = function()
        local path = file_browser.save_file(
            "convert_project", dialog,
            "Save Converted Project",
            file_filter,
            default_dir,
            default_name)
        if path and path ~= "" then
            dest_path = path
            qt.PROPERTIES.SET_TEXT(save_edit, dest_path)
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(browse_btn, browse_name)
    globals[#globals + 1] = browse_name

    -- Convert
    local convert_name = "__conversion_dialog_convert"
    _G[convert_name] = function()
        if not dest_path or dest_path == "" then return end

        -- Hide previous error, show progress
        qt.DISPLAY.SET_VISIBLE(error_label, false)
        set_converting(true)

        local ok, err = config.convert_fn(config.source_path, dest_path, progress.update)

        if ok then
            local has_warnings = #progress.get_log_lines() > 0
            if has_warnings then
                set_converting(false)
                progress.update(100, "Conversion complete with warnings")
                qt.DISPLAY.SET_VISIBLE(save_log_btn, true)
                qt.PROPERTIES.SET_TEXT(convert_btn, "Done")
                _G[convert_name] = function()
                    result_path = dest_path
                    qt.DIALOG.CLOSE(dialog, true)
                end
            else
                result_path = dest_path
                qt.DIALOG.CLOSE(dialog, true)
            end
        else
            set_converting(false)
            qt.PROPERTIES.SET_TEXT(error_label, "Error: " .. tostring(err))
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            log.error("Conversion failed: %s", tostring(err))
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(convert_btn, convert_name)
    globals[#globals + 1] = convert_name

    -- Cancel
    local cancel_name = "__conversion_dialog_cancel"
    _G[cancel_name] = function()
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(cancel_btn, cancel_name)
    globals[#globals + 1] = cancel_name

    -- Save Log
    local save_log_name = "__conversion_dialog_save_log"
    _G[save_log_name] = function()
        local log_path = file_browser.save_file(
            "conversion_log", dialog,
            "Save Conversion Log",
            "Text Files (*.txt)",
            default_dir,
            config.project_name .. "_conversion.txt")
        if log_path then
            local f = io.open(log_path, "w")
            if f then
                f:write(table.concat(progress.get_log_lines(), "\n"))
                f:close()
            end
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(save_log_btn, save_log_name)
    globals[#globals + 1] = save_log_name

    -- -----------------------------------------------------------------------
    -- Show (blocking)
    -- -----------------------------------------------------------------------
    qt.DIALOG.SET_LAYOUT(dialog, main_layout)
    qt.DIALOG.SHOW(dialog)

    -- Cleanup _G handlers
    for _, name in ipairs(globals) do
        _G[name] = nil
    end

    return result_path
end

return M
