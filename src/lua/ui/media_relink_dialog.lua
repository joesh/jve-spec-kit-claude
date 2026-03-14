--- media_relink_dialog: blocking modal for reconnecting offline media
--
-- Responsibilities:
-- - Show offline media list, let user pick search directory
-- - Run batch relink (path + filename strategies) with progress
-- - Display results, return relink_map on confirm
--
-- Non-goals:
-- - Metadata-based matching UI (advanced weights/sliders) — deferred until
--   slider-change-handler exists in Qt bindings
-- - Undo/redo (handled by RelinkMedia command)
--
-- Invariants:
-- - Requires qt_constants from C++ (asserts if missing)
-- - Returns relink_map table {media_id → new_path} on success, nil on cancel
-- - Uses file_browser for directory picker (auto-persists last dir)
--
-- @file media_relink_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")

--- Show the reconnect media dialog (blocking modal).
-- @param offline_media table Array of offline media records from media_relinker.find_offline_media
-- @param parent_window widget|nil Qt parent widget
-- @return table|nil relink_map {media_id → new_path} on success, nil on cancel
function M.show(offline_media, parent_window)
    assert(offline_media and #offline_media > 0,
        "media_relink_dialog.show: offline_media must be non-empty")

    local qt = require("core.qt_constants")
    local file_browser = require("core.file_browser")
    local media_relinker = require("core.media_relinker")

    -- State — restore last-used search dir if available
    local last_dir = file_browser.get_last_directory("relink_media")
    local search_dir = (last_dir and last_dir ~= "") and last_dir or nil
    local relink_map = nil   -- set on successful relink
    local globals = {}       -- _G handler names for cleanup

    -- Create dialog
    local dialog = qt.DIALOG.CREATE("Reconnect Media", 600, 420)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- -----------------------------------------------------------------------
    -- Header
    -- -----------------------------------------------------------------------
    local header = qt.WIDGET.CREATE_LABEL(
        string.format("Found %d offline media file(s)", #offline_media))
    qt.PROPERTIES.SET_STYLE(header, "font-weight: bold; font-size: 14px;")
    qt.LAYOUT.ADD_WIDGET(main_layout, header)
    qt.LAYOUT.ADD_SPACING(main_layout, 4)

    -- Offline file list (read-only text area showing names + old paths)
    local offline_lines = {}
    for _, m in ipairs(offline_media) do
        local name = m.name or m.media_id or "?"
        local path = m.file_path or "?"
        table.insert(offline_lines, string.format("%s  —  %s", name, path))
    end
    local offline_area = qt.WIDGET.CREATE_TEXT_EDIT(table.concat(offline_lines, "\n"))
    qt.CONTROL.SET_TEXT_EDIT_READ_ONLY(offline_area, true)
    qt.PROPERTIES.SET_SIZE(offline_area, 580, 100)
    qt.LAYOUT.ADD_WIDGET(main_layout, offline_area)
    qt.LAYOUT.ADD_SPACING(main_layout, 8)

    -- -----------------------------------------------------------------------
    -- Search directory row
    -- -----------------------------------------------------------------------
    local dir_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(dir_row, qt.WIDGET.CREATE_LABEL("Search in:"))
    local dir_edit = qt.WIDGET.CREATE_LINE_EDIT(search_dir or "")
    qt.CONTROL.SET_LINE_EDIT_READ_ONLY(dir_edit, true)
    qt.LAYOUT.ADD_WIDGET(dir_row, dir_edit)
    local browse_btn = qt.WIDGET.CREATE_BUTTON("Browse...")
    qt.LAYOUT.ADD_WIDGET(dir_row, browse_btn)
    qt.LAYOUT.ADD_LAYOUT(main_layout, dir_row)
    qt.LAYOUT.ADD_SPACING(main_layout, 8)

    -- Browse handler
    local browse_name = "__relink_dialog_browse"
    _G[browse_name] = function()
        local dir = file_browser.open_directory(
            "relink_media", parent_window or dialog,
            "Select Search Directory")
        if dir and dir ~= "" then
            search_dir = dir
            qt.PROPERTIES.SET_TEXT(dir_edit, dir)
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(browse_btn, browse_name)
    globals[#globals + 1] = browse_name

    -- -----------------------------------------------------------------------
    -- Results area (hidden initially)
    -- -----------------------------------------------------------------------
    local results_label = qt.WIDGET.CREATE_LABEL("")
    qt.DISPLAY.SET_VISIBLE(results_label, false)
    qt.LAYOUT.ADD_WIDGET(main_layout, results_label)

    local results_area = qt.WIDGET.CREATE_TEXT_EDIT("")
    qt.CONTROL.SET_TEXT_EDIT_READ_ONLY(results_area, true)
    qt.PROPERTIES.SET_SIZE(results_area, 580, 120)
    qt.DISPLAY.SET_VISIBLE(results_area, false)
    qt.LAYOUT.ADD_WIDGET(main_layout, results_area)

    -- -----------------------------------------------------------------------
    -- Error label (hidden initially)
    -- -----------------------------------------------------------------------
    local error_label = qt.WIDGET.CREATE_LABEL("")
    qt.PROPERTIES.SET_STYLE(error_label, "color: #ff6666;")
    qt.DISPLAY.SET_VISIBLE(error_label, false)
    qt.LAYOUT.ADD_WIDGET(main_layout, error_label)

    qt.LAYOUT.ADD_STRETCH(main_layout)

    -- -----------------------------------------------------------------------
    -- Button row
    -- -----------------------------------------------------------------------
    local btn_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_STRETCH(btn_row)

    local reconnect_btn = qt.WIDGET.CREATE_BUTTON("Reconnect")
    local cancel_btn = qt.WIDGET.CREATE_BUTTON("Cancel")

    -- Cancel handler
    local cancel_name = "__relink_dialog_cancel"
    _G[cancel_name] = function()
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(cancel_btn, cancel_name)
    globals[#globals + 1] = cancel_name

    -- Reconnect handler
    local reconnect_name = "__relink_dialog_reconnect"
    _G[reconnect_name] = function()
        -- Validate search dir
        if not search_dir or search_dir == "" then
            qt.PROPERTIES.SET_TEXT(error_label, "Select a search directory first")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        qt.DISPLAY.SET_VISIBLE(error_label, false)

        -- Run batch relink with path + filename strategies
        local options = { search_paths = { search_dir } }
        local results = media_relinker.batch_relink(offline_media, options)

        -- Build results display
        local result_lines = {}
        local map = {}

        for _, entry in ipairs(results.relinked) do
            local name = entry.media.name or entry.media.media_id or "?"
            table.insert(result_lines,
                string.format("[OK] %s → %s (%s)", name, entry.new_path, entry.strategy))
            map[entry.media.media_id or entry.media.id] = entry.new_path
        end
        for _, media in ipairs(results.failed) do
            local name = media.name or media.media_id or "?"
            table.insert(result_lines, string.format("[FAILED] %s", name))
        end

        -- Show results
        local summary = string.format("Reconnected %d of %d",
            #results.relinked, #offline_media)
        qt.PROPERTIES.SET_TEXT(results_label, summary)
        qt.DISPLAY.SET_VISIBLE(results_label, true)
        qt.PROPERTIES.SET_TEXT(results_area, table.concat(result_lines, "\n"))
        qt.DISPLAY.SET_VISIBLE(results_area, true)

        if #results.relinked == 0 then
            qt.PROPERTIES.SET_TEXT(error_label,
                "No media found. Try a different search directory.")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        -- Store map and rebind button to apply
        relink_map = map
        qt.PROPERTIES.SET_TEXT(reconnect_btn, "Apply")

        -- Rebind to close-on-apply
        _G[reconnect_name] = function()
            qt.DIALOG.CLOSE(dialog, true)
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(reconnect_btn, reconnect_name)
    globals[#globals + 1] = reconnect_name

    qt.LAYOUT.ADD_WIDGET(btn_row, reconnect_btn)
    qt.LAYOUT.ADD_SPACING(btn_row, 8)
    qt.LAYOUT.ADD_WIDGET(btn_row, cancel_btn)
    qt.LAYOUT.ADD_LAYOUT(main_layout, btn_row)

    -- -----------------------------------------------------------------------
    -- Show (blocking)
    -- -----------------------------------------------------------------------
    qt.DIALOG.SET_LAYOUT(dialog, main_layout)
    log.event("Showing Reconnect Media dialog (%d offline)", #offline_media)
    qt.DIALOG.SHOW(dialog)

    -- Cleanup _G handlers
    for _, name in ipairs(globals) do
        _G[name] = nil
    end

    return relink_map
end

return M
