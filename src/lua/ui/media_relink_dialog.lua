--- media_relink_dialog: blocking modal for reconnecting media (clip-level)
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
local json = require("dkjson")

--- Path to app-level matching rules preferences.
local function matching_rules_path()
    local home = os.getenv("HOME")
    assert(home, "matching_rules_path: HOME not set")
    return home .. "/.jve/relink_matching_rules.json"
end

--- Load matching rules from ~/.jve/ (app-level, persists across projects).
local function load_matching_rules()
    local matching_rules_dialog = require("ui.matching_rules_dialog")
    local path = matching_rules_path()
    local f = io.open(path, "r")
    if not f then
        return matching_rules_dialog.default_rules()
    end
    local content = f:read("*a")
    f:close()
    local decoded = json.decode(content)
    if type(decoded) ~= "table" then
        return matching_rules_dialog.default_rules()
    end
    return decoded
end

--- Save matching rules to ~/.jve/.
local function save_matching_rules(rules)
    local path = matching_rules_path()
    local encoded = json.encode(rules, {indent = true})
    local f = io.open(path, "w")
    assert(f, "save_matching_rules: failed to open " .. path)
    f:write(encoded)
    f:close()
end

--- Build clip_info structs from media records, pumping Qt events to stay responsive.
-- Updates the media list (not per-clip — too many) and header incrementally.
-- @param media_list table Array of media records to build clip_infos from
-- @param widgets table {qt, status_label, media_area, header} for live UI updates
local function build_clip_infos(media_list, widgets)
    local Clip = require("models.clip")
    local qt = widgets.qt
    local clip_infos = {}
    local media_lines = {}

    log.detail("build_clip_infos: gathering clips for %d media", #media_list)
    local t0 = os.clock()

    for mi, media in ipairs(media_list) do
        local tc_value, tc_rate = media:get_start_tc()
        local clips = Clip.find_clips_for_media(media.id)

        log.detail("  media %d/%d: %s — %d clips (tc=%s@%s)",
            mi, #media_list, media.name or media.id:sub(1,8),
            #clips, tostring(tc_value), tostring(tc_rate))

        -- Add media-level line (shown in the list)
        media_lines[#media_lines + 1] = string.format("  %s  —  %d clip(s)  (%s)",
            media.name or media.id:sub(1, 8), #clips, media:get_file_path())

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

        -- Update UI every 20 media
        if mi % 20 == 0 then
            if widgets.status_label then
                qt.PROPERTIES.SET_TEXT(widgets.status_label,
                    string.format("Loading... %d/%d media (%d clips)",
                        mi, #media_list, #clip_infos))
            end
            if widgets.media_area then
                qt.PROPERTIES.SET_TEXT(widgets.media_area, table.concat(media_lines, "\n"))
                qt.CONTROL.SCROLL_TEXT_EDIT_TO_END(widgets.media_area)
            end
            if widgets.header then
                qt.PROPERTIES.SET_TEXT(widgets.header,
                    string.format("Loading... %d clip(s) from %d/%d media",
                        #clip_infos, mi, #media_list))
            end
            qt.CONTROL.PROCESS_EVENTS()
        end
    end

    -- Final update
    if widgets.media_area then
        qt.PROPERTIES.SET_TEXT(widgets.media_area, table.concat(media_lines, "\n"))
    end
    if widgets.header then
        qt.PROPERTIES.SET_TEXT(widgets.header,
            string.format("Found %d clip(s) across %d media file(s)",
                #clip_infos, #media_list))
    end
    if widgets.status_label then
        qt.DISPLAY.SET_VISIBLE(widgets.status_label, false)
    end

    log.event("build_clip_infos: %d clips from %d media in %.1fs",
        #clip_infos, #media_list, os.clock() - t0)
    return clip_infos
end

--- Extract unique source volume/location roots from media paths.
-- Groups at the volume level: /Volumes/Name, D:\, /Users/name, etc.
local function extract_folder_roots(media_list)
    local root_counts = {}

    for _, media in ipairs(media_list) do
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

    local button_box = qt.CONTROL.CREATE_BUTTON_BOX()
    qt.CONTROL.BUTTON_BOX_ADD(button_box, "OK", "accept")
    qt.CONTROL.BUTTON_BOX_ADD(button_box, "Cancel", "reject")
    qt.LAYOUT.ADD_WIDGET(layout, button_box)

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
    qt.CONTROL.BUTTON_BOX_SET_HANDLER(button_box, "accepted", ok_name)

    local cancel_name = "__folder_priority_cancel"
    _G[cancel_name] = function()
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.BUTTON_BOX_SET_HANDLER(button_box, "rejected", cancel_name)

    qt.DIALOG.SET_LAYOUT(dialog, layout)
    qt.DIALOG.SHOW(dialog)

    _G[ok_name] = nil
    _G[cancel_name] = nil

    return result_order
end

--- Show the reconnect media dialog (blocking modal).
-- Shows dialog immediately, populates clip list asynchronously.
-- @param media_list table Non-empty array of media records to relink
-- @param parent_window userdata|nil Parent window for modal
-- @param project_id string Active project ID
-- @param opts table|nil {on_apply = function(results)} called before dialog closes
function M.show(media_list, parent_window, project_id, opts)
    assert(media_list and #media_list > 0,
        "media_relink_dialog.show: media_list must be non-empty")
    opts = opts or {}

    local qt = require("core.qt_constants")
    local file_browser = require("core.file_browser")
    local media_relinker = require("core.media_relinker")
    local progress_panel = require("ui.progress_panel")
    local matching_rules_dialog = require("ui.matching_rules_dialog")


    -- Extract folder roots immediately (cheap — just path parsing)
    local folder_roots = extract_folder_roots(media_list)
    local folder_priority = folder_roots

    -- State
    local last_dir = file_browser.get_last_directory("relink_media")
    local search_dir = (last_dir and last_dir ~= "") and last_dir or nil
    local relink_results = nil
    local clip_infos = nil  -- built after dialog appears
    local globals = {}

    local matching_rules = load_matching_rules()

    -- Create dialog
    local dialog = qt.DIALOG.CREATE("Reconnect Media", 700, 650, parent_window)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- -----------------------------------------------------------------------
    -- Header (shows loading count, updated after clip_infos built)
    -- -----------------------------------------------------------------------
    local header = qt.WIDGET.CREATE_LABEL(
        string.format("Loading %d media file(s)...", #media_list))
    qt.PROPERTIES.SET_STYLE(header, "font-weight: bold; font-size: 14px;")
    qt.LAYOUT.ADD_WIDGET(main_layout, header)
    qt.LAYOUT.ADD_SPACING(main_layout, 4)

    -- Clip list (initially shows loading message)
    local media_area = qt.WIDGET.CREATE_TEXT_EDIT("Loading...")
    qt.CONTROL.SET_TEXT_EDIT_READ_ONLY(media_area, true)
    qt.PROPERTIES.SET_SIZE(media_area, 660, 100)
    qt.LAYOUT.ADD_WIDGET(main_layout, media_area)
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
    qt.CONTROL.SET_BUTTON_AUTO_DEFAULT(browse_btn, false)
    qt.LAYOUT.ADD_WIDGET(dir_row, browse_btn)
    local rules_btn = qt.WIDGET.CREATE_BUTTON("Matching Rules...")
    qt.CONTROL.SET_BUTTON_AUTO_DEFAULT(rules_btn, false)
    qt.LAYOUT.ADD_WIDGET(dir_row, rules_btn)
    qt.LAYOUT.ADD_LAYOUT(main_layout, dir_row)

    -- Folder priority button (only if multiple source folders)
    local priority_btn = nil
    if #folder_roots > 1 then
        local priority_row = qt.LAYOUT.CREATE_HBOX()
        priority_btn = qt.WIDGET.CREATE_BUTTON(
            string.format("Folder Priority... (%d source folders)", #folder_roots))
        qt.CONTROL.SET_BUTTON_AUTO_DEFAULT(priority_btn, false)
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
            save_matching_rules(matching_rules)
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
    -- Button box: Relink (accept/default) + Cancel (reject)
    -- -----------------------------------------------------------------------
    local button_box = qt.CONTROL.CREATE_BUTTON_BOX()
    local relink_btn = qt.CONTROL.BUTTON_BOX_ADD(button_box, "Relink", "accept")
    local cancel_btn = qt.CONTROL.BUTTON_BOX_ADD(button_box, "Cancel", "reject")
    qt.CONTROL.SET_ENABLED(relink_btn, false)  -- disabled until clips loaded
    qt.LAYOUT.ADD_WIDGET(main_layout, button_box)

    -- Cancel (rejected signal)
    local cancel_name = "__relink_dialog_cancel"
    _G[cancel_name] = function()
        qt.DIALOG.CLOSE(dialog, false)
    end
    qt.CONTROL.BUTTON_BOX_SET_HANDLER(button_box, "rejected", cancel_name)
    globals[#globals + 1] = cancel_name

    -- Relink/Apply handler (accepted signal)
    local relink_name = "__relink_dialog_relink"
    _G[relink_name] = function()
        if not search_dir or search_dir == "" then
            qt.PROPERTIES.SET_TEXT(error_label, "Select a search directory first")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        qt.DISPLAY.SET_VISIBLE(error_label, false)

        -- Disable all controls during relink operation
        qt.CONTROL.SET_ENABLED(relink_btn, false)
        qt.CONTROL.SET_ENABLED(browse_btn, false)
        qt.CONTROL.SET_ENABLED(rules_btn, false)
        if priority_btn then qt.CONTROL.SET_ENABLED(priority_btn, false) end
        qt.PROPERTIES.SET_TEXT(relink_btn, "Relinking…")
        progress.reset()
        progress.show()
        qt.CONTROL.PROCESS_EVENTS()

        local options = {
            search_paths = { search_dir },
            matching_rules = matching_rules,
        }
        local results = media_relinker.relink_clips_batch(clip_infos, options, progress.update)
        progress.flush()
        results.folder_priority = folder_priority

        if #results.relinked == 0 then
            -- No matches — re-enable everything so user can retry
            qt.CONTROL.SET_ENABLED(relink_btn, true)
            qt.CONTROL.SET_ENABLED(browse_btn, true)
            qt.CONTROL.SET_ENABLED(rules_btn, true)
            if priority_btn then qt.CONTROL.SET_ENABLED(priority_btn, true) end
            qt.PROPERTIES.SET_TEXT(relink_btn, "Relink")
            qt.PROPERTIES.SET_TEXT(error_label,
                "No clips matched. Try a different directory or matching rules.")
            qt.DISPLAY.SET_VISIBLE(error_label, true)
            return
        end

        -- Success — show Apply button, keep other controls disabled
        relink_results = results
        qt.PROPERTIES.SET_TEXT(relink_btn, "Apply")
        qt.CONTROL.SET_ENABLED(relink_btn, true)

        _G[relink_name] = function()
            qt.CONTROL.SET_ENABLED(relink_btn, false)
            qt.CONTROL.SET_ENABLED(cancel_btn, false)
            qt.PROPERTIES.SET_TEXT(relink_btn, "Applying…")
            qt.PROPERTIES.SET_TEXT(header, "Applying relink changes…")
            qt.CONTROL.PROCESS_EVENTS()
            if opts.on_apply then
                opts.on_apply(relink_results)
            end
            qt.DIALOG.CLOSE(dialog, true)
        end
    end
    qt.CONTROL.BUTTON_BOX_SET_HANDLER(button_box, "accepted", relink_name)
    globals[#globals + 1] = relink_name

    -- -----------------------------------------------------------------------
    -- Show dialog immediately (non-blocking), then populate
    -- -----------------------------------------------------------------------
    qt.DIALOG.SET_LAYOUT(dialog, main_layout)
    log.event("Showing Reconnect Media dialog (%d media, %d source folders)",
        #media_list, #folder_roots)

    qt.DIALOG.SHOW(dialog, false)  -- non-blocking: dialog appears now

    -- Build clip_infos while dialog is visible (updates UI incrementally)
    clip_infos = build_clip_infos(media_list, {
        qt = qt,
        status_label = loading_label,
        media_area = media_area,
        header = header,
    })
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
