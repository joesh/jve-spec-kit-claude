--- media_relink_dialog: blocking modal for reconnecting media (clip-level)
--
-- Responsibilities:
-- - Show dialog immediately, populate clip list asynchronously (no beachball)
-- - "Matching Rules..." and "Folder Priority..." buttons
-- - Run clip-level batch relink with live progress
-- - Two-phase button: Relink → Apply
--
-- The apply callback receives a wrapper struct:
--   { relink = <media_relinker.relink_media_batch return>,
--     folder_priority = <array of folder roots in priority order> }
-- Keeping folder_priority separate from the relink struct preserves
-- media_relinker's documented return contract ({relinked, failed, ambiguous,
-- new_media}) — no mutation of a neighboring module's data shape.
--
-- @file media_relink_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")
local json = require("dkjson")

--- Pure: build a human-readable rich-text summary of a relink-results
--- struct ({relinked, failed, ambiguous}). Partitions `failed` into
--- "partial coverage" (entries with coverage info — the relinker did
--- find a same-basename candidate but rejected it for extent) and
--- "not found" (everything else). Exposed so tests exercise the
--- partitioning + formatting without touching Qt.
---
--- media_infos supplies per-media_id labels (name/path) so the summary
--- is readable — the relinker's failed[] is keyed by media_id only.
--- @param results {relinked, failed, ambiguous}
--- @param media_infos table<media_id, {name, path}>
--- @return string rich-text (HTML) summary
function M._format_results_summary(results, media_infos)
    -- Partition relinked[] into "clean" (full cover) and "partial"
    -- (file moved to a short candidate; clips short of coverage will
    -- render offline). Partial entries carry a `coverage` table.
    local clean_relinked, partial = {}, {}
    for _, r in ipairs(results.relinked or {}) do
        if r.coverage and r.coverage.kind == "partial_coverage" then
            partial[#partial + 1] = r
        else
            clean_relinked[#clean_relinked + 1] = r
        end
    end
    local n_relinked = #clean_relinked
    local n_ambiguous = results.ambiguous and #results.ambiguous or 0
    local unfindable = results.failed or {}

    local function name_for(media_id)
        local mi = media_infos and media_infos[media_id]
        if mi and mi.name and mi.name ~= "" then return mi.name end
        if mi and mi.path then return mi.path:match("[^/]+$") or mi.path end
        return media_id or "?"
    end
    local function basename(path)
        if type(path) ~= "string" then return "" end
        return path:match("[^/]+$") or path
    end

    local parts = {}
    parts[#parts + 1] = string.format(
        "<b>%d relinked</b> &nbsp;•&nbsp; <b>%d partial</b> &nbsp;•&nbsp; " ..
        "<b>%d not found</b>",
        n_relinked, #partial, #unfindable)
    if n_ambiguous > 0 then
        parts[#parts + 1] = string.format("&nbsp;•&nbsp; <b>%d ambiguous</b>",
            n_ambiguous)
    end

    if #partial > 0 then
        parts[#parts + 1] = "<br/><br/><b>Partial coverage — file found but short:</b>"
        local offline_note_mod = require("core.media.offline_note")
        for _, f in ipairs(partial) do
            local cov = f.coverage
            local nm = name_for(f.media_id)
            local cand = basename(cov.candidate_path)
            -- Shortfall against the media's source_extent (min source_in
            -- across clips, max source_out across clips) gives the
            -- worst-case head + worst-case tail the user will see
            -- somewhere in their timeline — the numbers that matter for
            -- "is this candidate good enough?". Per-clip iteration would
            -- give max(head+tail) on a single clip, which is a narrower,
            -- less actionable number for the summary.
            local mi = media_infos and media_infos[f.media_id]
            local detail = ""
            if mi and mi.source_extent_start and mi.source_extent_end then
                local sf = offline_note_mod.shortfall(
                    cov, mi.source_extent_start, mi.source_extent_end)
                if sf then
                    -- format_frame_delta tacks on a "(~Ns)" hint for any
                    -- delta ≥ rate. For audio media the note's `rate` is
                    -- the sample rate (e.g., 48000), so a 2-million-frame
                    -- shortfall renders as "2048004f (~42.7s)" instead of
                    -- a bare "2048004f" that the user reads as 22 hours
                    -- of video.
                    local fmt = offline_note_mod.format_frame_delta
                    if sf.head_missing > 0 and sf.tail_missing > 0 then
                        detail = string.format(" (short %s at head, %s at tail)",
                            fmt(sf.head_missing, sf.rate),
                            fmt(sf.tail_missing, sf.rate))
                    elseif sf.head_missing > 0 then
                        detail = string.format(" (short %s at head)",
                            fmt(sf.head_missing, sf.rate))
                    else
                        detail = string.format(" (short %s at tail)",
                            fmt(sf.tail_missing, sf.rate))
                    end
                end
            end
            parts[#parts + 1] = string.format(
                "<br/>&nbsp;&nbsp;%s &nbsp;→&nbsp; found <tt>%s</tt>%s",
                nm, cand, detail)
        end
    end

    if #unfindable > 0 then
        parts[#parts + 1] = "<br/><br/><b>Not found in search tree:</b>"
        for _, f in ipairs(unfindable) do
            local nm = name_for(f.media_id)
            local reason = f.reason or "unknown reason"
            parts[#parts + 1] = string.format(
                "<br/>&nbsp;&nbsp;%s &nbsp;—&nbsp; %s", nm, reason)
        end
    end

    if #partial == 0 and #unfindable == 0 and n_relinked > 0 then
        parts[#parts + 1] = "<br/><br/><i>All media relinked successfully.</i>"
    end

    return table.concat(parts)
end

--- Path to app-level matching rules preferences.
local function matching_rules_path()
    local home = os.getenv("HOME")
    assert(home, "matching_rules_path: HOME not set")
    return home .. "/.jve/relink_matching_rules.json"
end

--- Load matching rules from ~/.jve/ (app-level, persists across projects).
-- Missing file → defaults (first-run is legitimate).
-- Corrupt JSON → defaults, but log.warn so a silent "my prefs reset" is traceable.
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
        log.warn("load_matching_rules: %s is corrupt, reverting to defaults", path)
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

--- Build media_info structs from media records, pumping Qt events to stay responsive.
-- Each media_info carries media-level identity (id, path, name), TC origin,
-- and the source_extent (min source_in / max source_out across every clip
-- using this media). Extent is the input the matcher needs to decide
-- whether a candidate's covered range is sufficient for ALL dependents.
-- @param media_list table Array of media records
-- @param widgets table {qt, status_label, media_area, header} for live UI updates
local function build_media_infos(media_list, widgets)
    local qt = widgets.qt
    local media_infos = {}
    local media_lines = {}

    log.detail("build_media_infos: gathering source extents for %d media", #media_list)
    local t0 = qt_monotonic_s()

    -- Phase 1: collect each media's TC. get_start_tc reads hydrated
    -- metadata; _ensure_tc_extracted short-circuits when the file is
    -- offline (the relink scenario). Only media with a known TC rate
    -- participate in the batched extent query — we must NOT invent a
    -- default rate (rule 1.14). Media without TC will have a nil
    -- source extent, which the matcher handles (trimmed-media
    -- containment check returns false for nil extents).
    local tc_by_id = {}     -- media_id → {value, rate}; rate may be nil
    local rates_by_id = {}  -- per-stream target rates: {video_rate=, audio_sample_rate=}
    for _, media in ipairs(media_list) do
        -- Prefer V TC (frames at video fps). For audio-only files post-
        -- normalization V is nil — fall back to audio TC in samples at
        -- sample rate. The matcher operates in whatever unit stored_rate
        -- dictates, so an audio-only pairing of (samples, sr) is just as
        -- valid for containment checks as (frames, fps) is for V.
        local tc_value, tc_rate = media:get_start_tc()
        local atc_value, atc_rate = media:get_audio_start_tc()
        if not tc_value then
            tc_value, tc_rate = atc_value, atc_rate
        end
        tc_by_id[media.id] = { value = tc_value, rate = tc_rate }
        local audio_rate_for_extent = atc_rate or media.audio_sample_rate
        if audio_rate_for_extent == 0 then audio_rate_for_extent = nil end
        rates_by_id[media.id] = {
            video_rate = tc_rate,
            audio_sample_rate = audio_rate_for_extent,
        }
    end

    -- Phase 2: one SQL query fetches per-stream clip extents for every media
    -- in the batch. Replaces 1130× per-media get_source_extent calls.
    -- extents_by_id[mid] = { video = {min_in,max_out,rate}|nil,
    --                        audio = {min_in,max_out,rate}|nil }
    local Media = require("models.media")
    local extents_by_id = Media.batch_get_source_extents(rates_by_id)

    -- Phase 3: assemble media_info structs and pump the UI.
    -- Each clip's source_in/out is in either video frames (video clip) or
    -- audio samples (audio clip). The relinker's coverage check operates in
    -- a single coordinate system (frames at media.start_tc_rate). Project
    -- the audio extent (samples at audio_sample_rate) into video-frame
    -- space and union with the video extent. Sub-frame precision is lost
    -- in the projection — irrelevant for "does this file have enough
    -- content"; sample-accurate operations live elsewhere.
    for mi, media in ipairs(media_list) do
        local tc = tc_by_id[media.id]
        local ext = extents_by_id[media.id] or {}
        local v_extent = ext.video
        local a_extent = ext.audio
        local file_orig_tc = media:get_file_original_timecode()

        local extent_start, extent_end
        if v_extent then
            extent_start, extent_end = v_extent[1], v_extent[2]
        end
        if a_extent and tc.rate and a_extent.rate then
            -- samples-at-audio_sample_rate → frames-at-video_rate
            local a_in_frames  = math.floor(a_extent[1] * tc.rate / a_extent.rate + 0.5)
            local a_out_frames = math.floor(a_extent[2] * tc.rate / a_extent.rate + 0.5)
            if not extent_start or a_in_frames < extent_start then
                extent_start = a_in_frames
            end
            if not extent_end or a_out_frames > extent_end then
                extent_end = a_out_frames
            end
        end

        media_lines[#media_lines + 1] = string.format("  %s  (%s)",
            media.name or media.id:sub(1, 8), media:get_file_path())

        media_infos[#media_infos + 1] = {
            media_id = media.id,
            media_path = media:get_file_path(),
            media_name = media.name or media.id,
            media_start_tc_value = tc.value,
            media_start_tc_rate = tc.rate,
            media_file_original_tc = file_orig_tc,
            width = media.width or 0,
            height = media.height or 0,
            source_extent_start = extent_start,
            source_extent_end   = extent_end,
        }

        -- Update UI every 100 media — the per-media loop is now mostly
        -- Lua work, so we can refresh less often than before without
        -- losing responsiveness.
        if mi % 100 == 0 then
            if widgets.status_label then
                qt.PROPERTIES.SET_TEXT(widgets.status_label,
                    string.format("Loading... %d/%d media", mi, #media_list))
            end
            if widgets.media_area then
                qt.PROPERTIES.SET_TEXT(widgets.media_area, table.concat(media_lines, "\n"))
                qt.CONTROL.SCROLL_TEXT_EDIT_TO_END(widgets.media_area)
            end
            if widgets.header then
                qt.PROPERTIES.SET_TEXT(widgets.header,
                    string.format("Loading... %d/%d media", mi, #media_list))
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
            string.format("Found %d media file(s)", #media_list))
    end
    if widgets.status_label then
        qt.DISPLAY.SET_VISIBLE(widgets.status_label, false)
    end

    log.event("build_media_infos: %d media in %.1fs", #media_list, qt_monotonic_s() - t0)
    return media_infos
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

--- Show folder priority dialog — drag-to-reorder list.
-- Items appear top-to-bottom in priority order: top row = highest priority.
-- The user drags rows to reorder. OK returns the resulting order;
-- Cancel returns nil (caller keeps the prior order).
local function show_folder_priority_dialog(folder_roots, parent_window)
    local qt = require("core.qt_constants")

    local dialog = qt.DIALOG.CREATE("Folder Priority", 650, 400, parent_window)
    local layout = qt.LAYOUT.CREATE_VBOX()

    local header = qt.WIDGET.CREATE_LABEL(
        "When the same filename exists in multiple source folders,\n" ..
        "higher-priority folders win.\n\n" ..
        "Drag rows to reorder — top = highest priority.")
    qt.LAYOUT.ADD_WIDGET(layout, header)
    qt.LAYOUT.ADD_SPACING(layout, 8)

    -- QTreeWidget in InternalMove drag-drop mode gives us drag-reorder
    -- natively. One column → reads as a flat list.
    local tree = qt.WIDGET.CREATE_TREE()
    qt.CONTROL.SET_TREE_HEADERS(tree, { "Source Folder (drag to reorder)" })
    qt.CONTROL.SET_TREE_DRAG_DROP_MODE(tree, "internal")

    -- Map the tree-item id (assigned by add_tree_item) → folder root string,
    -- so we can reconstruct order after the user drags things around.
    local id_to_root = {}
    for _, root in ipairs(folder_roots) do
        local item_id = qt.CONTROL.ADD_TREE_ITEM(tree, { root })
        id_to_root[item_id] = root
    end
    qt.LAYOUT.ADD_WIDGET(layout, tree)

    local button_box = qt.CONTROL.CREATE_BUTTON_BOX()
    qt.CONTROL.BUTTON_BOX_ADD(button_box, "OK", "accept")
    qt.CONTROL.BUTTON_BOX_ADD(button_box, "Cancel", "reject")
    qt.LAYOUT.ADD_WIDGET(layout, button_box)

    local result_order = nil

    local ok_name = "__folder_priority_ok"
    _G[ok_name] = function()
        -- Read visual top-to-bottom order from the tree after any drags.
        local ordered_ids = qt.CONTROL.GET_TREE_ITEMS_IN_ORDER(tree)
        result_order = {}
        for _, item_id in ipairs(ordered_ids) do
            local root = id_to_root[item_id]
            assert(root, string.format(
                "folder priority dialog: tree returned unknown item id %s",
                tostring(item_id)))
            result_order[#result_order + 1] = root
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
-- @param opts table|nil {on_apply = function(results)} called before dialog
--   closes, where results = { relink = <relink_media_batch return>,
--   folder_priority = <array of folder roots> }
function M.show(media_list, parent_window, opts)
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
    local media_infos = nil  -- built after dialog appears
    local globals = {}

    local matching_rules = load_matching_rules()

    -- Create dialog
    local dialog = qt.DIALOG.CREATE("Reconnect Media", 700, 650, parent_window)
    local main_layout = qt.LAYOUT.CREATE_VBOX()

    -- -----------------------------------------------------------------------
    -- Header (shows loading count, updated after media_infos built)
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

    -- Results summary: shown after relink completes. Distinguishes
    -- three buckets:
    --   1. relinked — good matches we'll apply
    --   2. partial — same-basename file found but doesn't cover the
    --      full clip range; clips will be flagged on the timeline
    --   3. unfindable — no same-basename file in the search tree
    -- The user needs to see the per-media list for (2) and (3) so they
    -- know which clips to expect as offline post-apply and why. Rich-
    -- text QLabel is fine for a few hundred lines; if the list grows
    -- past that, promote to a scrollable list widget later.
    local results_summary = qt.WIDGET.CREATE_LABEL("")
    qt.PROPERTIES.SET_STYLE(results_summary,
        "color: #dddddd; font-family: monospace; font-size: 11px; " ..
        "padding: 6px; background: #1e1e1e; border: 1px solid #333;")
    if qt.PROPERTIES.SET_WORD_WRAP then
        qt.PROPERTIES.SET_WORD_WRAP(results_summary, true)
    end
    if qt.PROPERTIES.SET_TEXT_FORMAT then
        qt.PROPERTIES.SET_TEXT_FORMAT(results_summary, "rich")
    end
    qt.DISPLAY.SET_VISIBLE(results_summary, false)
    qt.LAYOUT.ADD_WIDGET(main_layout, results_summary)

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

        local Clip = require("models.clip")
        local options = {
            search_paths = { search_dir },
            matching_rules = matching_rules,
            clip_loader = function(media_id)
                local clips = Clip.find_clips_for_media(media_id)
                local entries = {}
                for _, clip in ipairs(clips) do
                    -- V13: every clip is a timeline placement; no
                    -- master/timeline kind discriminator needed.
                    entries[#entries + 1] = {
                        clip_id = clip.id,
                        track_type = clip.track_type,
                        source_in = clip.source_in,
                        source_out = clip.source_out,
                        fps_num = clip.frame_rate.fps_numerator,
                        fps_den = clip.frame_rate.fps_denominator,
                    }
                end
                return entries
            end,
        }
        local results = media_relinker.relink_media_batch(media_infos, options, progress.update)
        progress.flush()

        -- Always show the results summary — user needs to see what the
        -- relinker found AND what it didn't, broken down by failure
        -- kind. The distinction between "partial coverage" and "not
        -- found" is load-bearing: partial means Apply will flag clips
        -- with a shortfall note (they stay offline but with an
        -- actionable message); not-found means the user needs to
        -- locate the file or accept the clips remaining offline.
        local info_lookup = {}
        for _, mi in ipairs(media_infos) do
            info_lookup[mi.media_id] = {
                name = mi.media_name,
                path = mi.media_path,
                source_extent_start = mi.source_extent_start,
                source_extent_end   = mi.source_extent_end,
            }
        end
        qt.PROPERTIES.SET_TEXT(results_summary,
            M._format_results_summary(results, info_lookup))
        qt.DISPLAY.SET_VISIBLE(results_summary, true)

        if #results.relinked == 0 then
            -- Nothing to apply — re-enable everything so user can retry
            qt.CONTROL.SET_ENABLED(relink_btn, true)
            qt.CONTROL.SET_ENABLED(browse_btn, true)
            qt.CONTROL.SET_ENABLED(rules_btn, true)
            if priority_btn then qt.CONTROL.SET_ENABLED(priority_btn, true) end
            qt.PROPERTIES.SET_TEXT(relink_btn, "Relink")
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
                opts.on_apply({
                    relink          = relink_results,
                    folder_priority = folder_priority,
                })
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

    -- Build media_infos while dialog is visible (updates UI incrementally)
    media_infos = build_media_infos(media_list, {
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
