--- media_relink_dialog: blocking modal for reconnecting offline media (clip-level)
--
-- Responsibilities:
-- - Show dialog immediately, populate clip list asynchronously (no beachball)
-- - "Matching Rules..." and "Folder Priority..." buttons
-- - Run clip-level batch relink with live progress
-- - Two-phase button: Relink → Apply
-- - Return relink results + folder priority on confirm, nil on cancel
--
-- @file media_relink_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")

--- Build clip_info structs from offline media, pumping Qt events to stay responsive.
local function build_clip_infos(offline_media, qt, status_label)
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

        -- Pump Qt events every 50 media to stay responsive
        if mi % 50 == 0 then
            if status_label then
                qt.PROPERTIES.SET_TEXT(status_label,
                    string.format("Loading clips... %d/%d media (%d clips)",
                        mi, #offline_media, #clip_infos))
            end
            qt.CONTROL.PROCESS_EVENTS()
        end
    end

    log.event("build_clip_infos: %d clips from %d media in %.1fs",
        #clip_infos, #offline_media, os.clock() - t0)
    return clip_infos
end

--- Extract unique source volume/location roots from media paths.
-- Groups at the volume level: /Volumes/Name, D:\, /Users/name, etc.
local function extract_folder_roots(offline_media)
    local root_counts = {}

    for _, media in ipairs(offline_media) do
        local path = media:get_file_path()
        local root
        if path:match("^/Volumes/") then
            -- /Volumes/DriveName
            root = path:match("^(/Volumes/[^/]+)")
        elseif path:match("^/Users/") then
            -- /Users/username
            root = path:match("^(/Users/[^/]+)")
        elseif path:match("^%a:\\") then
            -- Windows: D:\
            root = path:match("^(%a:\\)")
        elseif path:sub(1, 1) == "/" then
            -- Other unix: first two components
            root = path:match("^(/[^/]+/[^/]+)")
        else
            root = path:match("^([^/\\]+)")
        end

        if root then
            root_counts[root] = (root_counts[root] or 0) + 1
        end
    end

    local roots = {}
    for root, count in pairs(root_counts) do
        roots[#roots + 1] = {root = root, count = count}
    end
    table.sort(roots, function(a, b) return a.count > b.count end)

    local result = {}
    for _, r in ipairs(roots) do
        result[#result + 1] = r.root
    end
    return result
end

--- Show folder priority dialog (single dialog, all folders).
local function show_folder_priority_dialog(folder_roots, parent_window)
    local qt = require("core.qt_constants")

    local dialog = qt.DIALOG.CREATE("Folder Priority", 650, 400, parent_window)
    local layout = qt.LAYOUT.CREATE_VBOX()

    local header = qt.WIDGET.CREATE_LABEL(
        "When the same filename exists in multiple source folders,\n" ..
        "higher-priority folders win. Set priority 1 = highest.")
    qt.LAYOUT.ADD_WIDGET(layout, header)
    qt.LAYOUT.ADD_SPACING(layout, 8)

    local combos = {}
    for i, root in ipairs(folder_roots) do
        local row = qt.LAYOUT.CREATE_HBOX()
        local combo = qt.WIDGET.CREATE_COMBOBOX()
        for p = 1, #folder_roots do
            qt.PROPERTIES.ADD_COMBOBOX_ITEM(combo, tostring(p))
        end
        qt.PROPERTIES.SET_COMBOBOX_CURRENT_INDEX(combo, i - 1)
        qt.LAYOUT.ADD_WIDGET(row, combo)
        qt.LAYOUT.ADD_WIDGET(row, qt.WIDGET.CREATE_LABEL("  " .. root))
        qt.LAYOUT.ADD_STRETCH(row)
        qt.LAYOUT.ADD_LAYOUT(layout, row)
        combos[#combos + 1] = {combo = combo, root = root}
    end

    qt.LAYOUT.ADD_STRETCH(layout)

    local btn_row = qt.LAYOUT.CREATE_HBOX()
    qt.LAYOUT.ADD_STRETCH(btn_row)
    local ok_btn = qt.WIDGET.CREATE_BUTTON("OK")
    local cancel_btn = qt.WIDGET.CREATE_BUTTON("Cancel")

    local result_order = nil

    local ok_name = "__folder_priority_ok"
    _G[ok_name] = function()
        local assignments = {}
        for _, entry in ipairs(combos) do
            local idx = qt.PROPERTIES.GET_COMBOBOX_CURRENT_INDEX(entry.combo)
            assignments[#assignments + 1] = {priority = (idx or 0) + 1, root = entry.root}
        end
        table.sort(assignments, function(a, b) return a.priority < b.priority end)
        result_order = {}
        for _, a in ipairs(assignments) do
            result_order[#result_order + 1] = a.root
        end
        qt.DIALOG.CLOSE(dialog, true)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(ok_btn, ok_name)

    local cancel_name = "__folder_priority_cancel"
    _G[cancel_name] = function()
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.SET_BUTTON_CLICK_HANDLER(cancel_btn, cancel_name)

    qt.LAYOUT.ADD_WIDGET(btn_row, ok_btn)
    qt.LAYOUT.ADD_SPACING(btn_row, 8)
    qt.LAYOUT.ADD_WIDGET(btn_row, cancel_btn)
    qt.LAYOUT.ADD_LAYOUT(layout, btn_row)

    qt.DIALOG.SET_LAYOUT(dialog, layout)
    qt.DIALOG.SHOW(dialog)

    _G[ok_name] = nil
    _G[cancel_name] = nil

    return result_order
end

--- Show the reconnect media dialog (blocking modal).
-- Shows dialog immediately, populates clip list asynchronously.
function M.show(offline_media, parent_window, project_id)
    assert(offline_media and #offline_media > 0,
        "media_relink_dialog.show: offline_media must be non-empty")

    local qt = require("core.qt_constants")
    local file_browser = require("core.file_browser")
    local media_relinker = require("core.media_relinker")
    local progress_panel = require("ui.progress_panel")
    local matching_rules_dialog = require("ui.matching_rules_dialog")
    local database = require("core.database")

    -- Extract folder roots immediately (cheap — just path parsing)
    local folder_roots = extract_folder_roots(offline_media)
    local folder_priority = folder_roots

    -- State
    local last_dir = file_browser.get_last_directory("relink_media")
    local search_dir = (last_dir and last_dir ~= "") and last_dir or nil
    local relink_results = nil
    local clip_infos = nil  -- built after dialog appears
    local globals = {}

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
    -- Header (shows loading count, updated after clip_infos built)
    -- -----------------------------------------------------------------------
    local header = qt.WIDGET.CREATE_LABEL(
        string.format("Loading %d offline media file(s)...", #offline_media))
    qt.PROPERTIES.SET_STYLE(header, "font-weight: bold; font-size: 14px;")
    qt.LAYOUT.ADD_WIDGET(main_layout, header)
    qt.LAYOUT.ADD_SPACING(main_layout, 4)

    -- Clip list (initially shows loading message)
    local clip_area = qt.WIDGET.CREATE_TEXT_EDIT("Loading clips...")
    qt.CONTROL.SET_TEXT_EDIT_READ_ONLY(clip_area, true)
    qt.PROPERTIES.SET_SIZE(clip_area, 660, 100)
    qt.LAYOUT.ADD_WIDGET(main_layout, clip_area)
    qt.LAYOUT.ADD_SPACING(main_layout, 4)

    -- Loading status label (visible during clip loading)
    local loading_label = qt.WIDGET.CREATE_LABEL("Loading...")
    qt.LAYOUT.ADD_WIDGET(main_layout, loading_label)

    -- -----------------------------------------------------------------------
    -- Search directory row + buttons
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

    -- Folder priority button (only if multiple source folders)
    if #folder_roots > 1 then
        local priority_row = qt.LAYOUT.CREATE_HBOX()
        local priority_btn = qt.WIDGET.CREATE_BUTTON(
            string.format("Folder Priority... (%d source folders)", #folder_roots))
        qt.LAYOUT.ADD_WIDGET(priority_row, priority_btn)
        qt.LAYOUT.ADD_STRETCH(priority_row)
        qt.LAYOUT.ADD_LAYOUT(main_layout, priority_row)

        local priority_name = "__relink_dialog_priority"
        _G[priority_name] = function()
            local updated = show_folder_priority_dialog(folder_priority, dialog)
            if updated then
                folder_priority = updated
                log.event("folder priority updated: %s", table.concat(folder_priority, " > "))
            end
        end
        qt.CONTROL.SET_BUTTON_CLICK_HANDLER(priority_btn, priority_name)
        globals[#globals + 1] = priority_name
    end

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

    -- Error label (hidden)
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
    qt.CONTROL.SET_ENABLED(relink_btn, false)  -- disabled until clips loaded
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

        local options = {
            search_paths = { search_dir },
            matching_rules = matching_rules,
        }
        local results = media_relinker.relink_clips_batch(clip_infos, options, progress.update)
        results.folder_priority = folder_priority

        qt.CONTROL.SET_ENABLED(browse_btn, true)
        qt.CONTROL.SET_ENABLED(rules_btn, true)

        if #results.relinked == 0 then
            qt.CONTROL.SET_ENABLED(relink_btn, true)
            qt.PROPERTIES.SET_TEXT(error_label,
                "No clips matched. Try a different directory or matching rules.")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        relink_results = results
        qt.PROPERTIES.SET_TEXT(relink_btn, "Apply")
        qt.CONTROL.SET_ENABLED(relink_btn, true)

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
    -- Show dialog immediately (non-blocking), then populate
    -- -----------------------------------------------------------------------
    qt.DIALOG.SET_LAYOUT(dialog, main_layout)
    log.event("Showing Reconnect Media dialog (%d media, %d source folders)",
        #offline_media, #folder_roots)

    qt.DIALOG.SHOW(dialog, false)  -- non-blocking: dialog appears now

    -- Build clip_infos while dialog is visible (with PROCESS_EVENTS)
    clip_infos = build_clip_infos(offline_media, qt, loading_label)

    -- Populate clip list
    local clip_lines = {}
    for _, info in ipairs(clip_infos) do
        clip_lines[#clip_lines + 1] = string.format(
            "  %s  —  %s  (%s)",
            info.clip_name or info.clip_id:sub(1, 8),
            info.media_name,
            info.media_path)
    end
    qt.PROPERTIES.SET_TEXT(clip_area, table.concat(clip_lines, "\n"))
    qt.PROPERTIES.SET_TEXT(header,
        string.format("Found %d offline clip(s) across %d media file(s)",
            #clip_infos, #offline_media))
    qt.DISPLAY.SET_VISIBLE(loading_label, false)
    qt.CONTROL.SET_ENABLED(relink_btn, true)

    -- Now block waiting for user interaction
    qt.DIALOG.SHOW(dialog)

    -- Cleanup
    for _, name in ipairs(globals) do
        _G[name] = nil
    end

    return relink_results
end

return M
