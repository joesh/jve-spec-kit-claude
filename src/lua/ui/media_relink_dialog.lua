--- media_relink_dialog: blocking modal for reconnecting offline media (clip-level)
--
-- Responsibilities:
-- - Show offline clip list with status icons, search directory picker
-- - "Matching Rules..." button for configuring match criteria
-- - Run clip-level batch relink with live progress
-- - Two-phase button: Relink → Apply
-- - Return relink results on confirm, nil on cancel
--
-- Non-goals:
-- - Undo/redo (handled by RelinkClips command)
--
-- Invariants:
-- - Requires qt_constants from C++ (asserts if missing)
-- - Returns results table on success, nil on cancel
-- - Uses file_browser for directory picker (auto-persists last dir)
--
-- @file media_relink_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")

--- Build clip_info structs from offline media.
-- Gathers all clips referencing each offline media record.
-- @param offline_media table Array of offline media records
-- @return table Array of clip_info structs per the relink_clips_batch contract
local function build_clip_infos(offline_media)
    local Clip = require("models.clip")
    local clip_infos = {}

    log.detail("build_clip_infos: gathering clips for %d offline media", #offline_media)
    local t0 = os.clock()

    for mi, media in ipairs(offline_media) do
        local tc_value, tc_rate = media:get_start_tc()
        local clips = Clip.find_clips_for_media(media.id)

        log.detail("  media %d/%d: %s — %d clips (tc=%s@%s)",
            mi, #offline_media, media.name or media.id:sub(1,8),
            #clips, tostring(tc_value), tostring(tc_rate))

        for _, clip in ipairs(clips) do
            clip_infos[#clip_infos + 1] = {
                clip_id = clip.id,
                media_id = media.id,
                source_in = clip.source_in,
                source_out = clip.source_out,
                fps_num = clip.rate.fps_numerator,
                fps_den = clip.rate.fps_denominator,
                media_start_tc_value = tc_value,
                media_start_tc_rate = tc_rate,
                media_path = media:get_file_path(),
                media_name = media.name or media.id,
                width = media.width or 0,
                height = media.height or 0,
                clip_kind = clip.clip_kind,
                clip_name = clip.name,
            }
        end
    end

    log.event("build_clip_infos: %d clips from %d media in %.1fs",
        #clip_infos, #offline_media, os.clock() - t0)
    return clip_infos
end

--- Show the reconnect media dialog (blocking modal).
-- @param offline_media table Array of offline media records
-- @param parent_window widget|nil Qt parent widget
-- @param project_id string Current project ID (for matching rules persistence)
-- @return table|nil Results {relinked, failed, ambiguous, new_media} on success, nil on cancel
function M.show(offline_media, parent_window, project_id)
    assert(offline_media and #offline_media > 0,
        "media_relink_dialog.show: offline_media must be non-empty")

    local qt = require("core.qt_constants")
    local file_browser = require("core.file_browser")
    local media_relinker = require("core.media_relinker")
    local progress_panel = require("ui.progress_panel")
    local matching_rules_dialog = require("ui.matching_rules_dialog")
    local database = require("core.database")

    -- Build clip info structs
    local clip_infos = build_clip_infos(offline_media)

    -- State
    local last_dir = file_browser.get_last_directory("relink_media")
    local search_dir = (last_dir and last_dir ~= "") and last_dir or nil
    local relink_results = nil
    local globals = {}

    -- Load matching rules from project settings (or defaults)
    local matching_rules
    if project_id then
        matching_rules = database.get_project_setting(project_id, "relink_matching_rules")
    end
    if not matching_rules then
        matching_rules = matching_rules_dialog.default_rules()
    end

    -- Create dialog
    local dialog = qt.DIALOG.CREATE("Reconnect Media", 700, 650, parent_window)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- -----------------------------------------------------------------------
    -- Header
    -- -----------------------------------------------------------------------
    local header = qt.WIDGET.CREATE_LABEL(
        string.format("Found %d offline clip(s) across %d media file(s)",
            #clip_infos, #offline_media))
    qt.PROPERTIES.SET_STYLE(header, "font-weight: bold; font-size: 14px;")
    qt.LAYOUT.ADD_WIDGET(main_layout, header)
    qt.LAYOUT.ADD_SPACING(main_layout, 4)

    -- Clip list (showing clip names + media paths)
    local clip_lines = {}
    for _, info in ipairs(clip_infos) do
        clip_lines[#clip_lines + 1] = string.format(
            "  %s  —  %s  (%s)",
            info.clip_name or info.clip_id:sub(1, 8),
            info.media_name,
            info.media_path)
    end
    local clip_area = qt.WIDGET.CREATE_TEXT_EDIT(table.concat(clip_lines, "\n"))
    qt.CONTROL.SET_TEXT_EDIT_READ_ONLY(clip_area, true)
    qt.PROPERTIES.SET_SIZE(clip_area, 660, 100)
    qt.LAYOUT.ADD_WIDGET(main_layout, clip_area)
    qt.LAYOUT.ADD_SPACING(main_layout, 4)

    -- -----------------------------------------------------------------------
    -- Search directory row + Matching Rules button
    -- -----------------------------------------------------------------------
    local dir_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_WIDGET(dir_row, qt.WIDGET.CREATE_LABEL("Search in:"))
    local dir_edit = qt.WIDGET.CREATE_LINE_EDIT(search_dir or "")
    qt.CONTROL.SET_LINE_EDIT_READ_ONLY(dir_edit, true)
    qt.LAYOUT.ADD_WIDGET(dir_row, dir_edit)
    local browse_btn = qt.WIDGET.CREATE_BUTTON("Browse...")
    qt.LAYOUT.ADD_WIDGET(dir_row, browse_btn)
    local rules_btn = qt.WIDGET.CREATE_BUTTON("Matching Rules...")
    qt.LAYOUT.ADD_WIDGET(dir_row, rules_btn)
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

    -- Matching Rules handler
    local rules_name = "__relink_dialog_rules"
    _G[rules_name] = function()
        local updated = matching_rules_dialog.show(matching_rules, dialog)
        if updated then
            matching_rules = updated
            -- Persist to project settings
            if project_id then
                database.set_project_setting(project_id, "relink_matching_rules", matching_rules)
            end
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(rules_btn, rules_name)
    globals[#globals + 1] = rules_name

    -- -----------------------------------------------------------------------
    -- Progress panel
    -- -----------------------------------------------------------------------
    local progress = progress_panel.create(main_layout, {log_height = 200, width = 660})

    -- -----------------------------------------------------------------------
    -- Error label (hidden)
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

    local relink_btn = qt.WIDGET.CREATE_BUTTON("Relink")
    local cancel_btn = qt.WIDGET.CREATE_BUTTON("Cancel")

    local cancel_name = "__relink_dialog_cancel"
    _G[cancel_name] = function()
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(cancel_btn, cancel_name)
    globals[#globals + 1] = cancel_name

    -- Relink handler
    local relink_name = "__relink_dialog_relink"
    _G[relink_name] = function()
        if not search_dir or search_dir == "" then
            qt.PROPERTIES.SET_TEXT(error_label, "Select a search directory first")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        qt.DISPLAY.SET_VISIBLE(error_label, false)
        qt.CONTROL.SET_ENABLED(relink_btn, false)
        qt.CONTROL.SET_ENABLED(browse_btn, false)
        qt.CONTROL.SET_ENABLED(rules_btn, false)
        progress.reset()
        progress.show()

        -- Run clip-level batch relink
        local options = {
            search_paths = { search_dir },
            matching_rules = matching_rules,
        }
        local results = media_relinker.relink_clips_batch(clip_infos, options, progress.update)

        -- Re-enable controls
        qt.CONTROL.SET_ENABLED(browse_btn, true)
        qt.CONTROL.SET_ENABLED(rules_btn, true)

        if #results.relinked == 0 then
            qt.CONTROL.SET_ENABLED(relink_btn, true)
            qt.PROPERTIES.SET_TEXT(error_label,
                "No clips matched. Try a different directory or matching rules.")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        -- Store results and switch to Apply mode
        relink_results = results
        qt.PROPERTIES.SET_TEXT(relink_btn, "Apply")
        qt.CONTROL.SET_ENABLED(relink_btn, true)

        -- Rebind to close-on-apply
        _G[relink_name] = function()
            qt.DIALOG.CLOSE(dialog, true)
        end
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(relink_btn, relink_name)
    globals[#globals + 1] = relink_name

    qt.LAYOUT.ADD_WIDGET(btn_row, relink_btn)
    qt.LAYOUT.ADD_SPACING(btn_row, 8)
    qt.LAYOUT.ADD_WIDGET(btn_row, cancel_btn)
    qt.LAYOUT.ADD_LAYOUT(main_layout, btn_row)

    -- -----------------------------------------------------------------------
    -- Show (blocking)
    -- -----------------------------------------------------------------------
    qt.DIALOG.SET_LAYOUT(dialog, main_layout)
    log.event("Showing Reconnect Media dialog (%d clips, %d media)",
        #clip_infos, #offline_media)
    qt.DIALOG.SHOW(dialog)

    -- Cleanup
    for _, name in ipairs(globals) do
        _G[name] = nil
    end

    return relink_results
end

return M
