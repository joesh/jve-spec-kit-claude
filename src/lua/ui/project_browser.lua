-- Project Browser - Media library and bin management
-- Shows imported media files, allows drag-to-timeline
-- Mimics DaVinci Resolve Media Pool style

local M = {}
local db = require("core.database")
local ui_constants = require("core.ui_constants")
local focus_manager = require("ui.focus_manager")
local command_manager = require("core.command_manager")
local command_scope = require("core.command_scope")
local Command = require("command")
local browser_state = require("ui.project_browser.browser_state")
local frame_utils = require("core.frame_utils")
local qt_constants = require("core.qt_constants")

local handler_seq = 0

local REFRESH_COMMANDS = {
    ImportMedia = true,
    ImportFCP7XML = true,
    DeleteMasterClip = true,
    DeleteSequence = true,
    ImportResolveProject = true,
    ImportResolveDatabase = true,
    RenameItem = true,
}

local command_listener_registered = false
local is_restoring_selection = false

local function should_refresh_command(command_type)
    return command_type and REFRESH_COMMANDS[command_type] == true
end

local function handle_command_event(event)
    if not event or not event.command then
        return
    end
    local command_type = event.command.type or event.command.command_type
    if should_refresh_command(command_type) then
        M.refresh()
    end
end

local function ensure_command_listener()
    if command_listener_registered then
        return
    end
    if command_manager and command_manager.add_listener then
        command_manager.add_listener(handle_command_event)
        command_listener_registered = true
    end
end

local function register_handler(callback)
    handler_seq = handler_seq + 1
    local name = "__project_browser_handler_" .. handler_seq
    _G[name] = function(...)
        callback(...)
    end
    return name
end

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end
    local stripped = value:match("^%s*(.-)%s*$")
    if stripped == nil then
        return ""
    end
    return stripped
end

local function finalize_pending_rename(new_name)
    local pending = M.pending_rename
    if not pending then
        return
    end

    if qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE then
        qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE(M.tree, pending.tree_id, false)
    end

    local trimmed_name = trim(new_name or "")
    if trimmed_name == "" then
        if qt_constants.CONTROL.SET_TREE_ITEM_TEXT then
            qt_constants.CONTROL.SET_TREE_ITEM_TEXT(M.tree, pending.tree_id, pending.original_name or "", 0)
        end
        pending.preview_name = nil
        M.pending_rename = nil
        return
    end

    if trimmed_name == (pending.original_name or "") then
        pending.preview_name = nil
        M.pending_rename = nil
        return
    end

    local project_id = M.project_id or db.get_current_project_id()
    local cmd = Command.create("RenameItem", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("target_type", pending.target_type)
    cmd:set_parameter("target_id", pending.target_id)
    cmd:set_parameter("new_name", trimmed_name)
    cmd:set_parameter("previous_name", pending.original_name)

    local result = command_manager.execute(cmd)
    if result and result.success then
        print(string.format("RenameItem executed for %s → %s", tostring(pending.target_id), trimmed_name))
    else
        print(string.format("RenameItem failed for %s → %s (%s)", tostring(pending.target_id), trimmed_name, result and result.error_message or "unknown error"))
        if qt_constants.CONTROL.SET_TREE_ITEM_TEXT then
            qt_constants.CONTROL.SET_TREE_ITEM_TEXT(M.tree, pending.tree_id, pending.original_name or "", 0)
        end
        M.pending_rename = nil
        return
    end

    local info = M.item_lookup and M.item_lookup[tostring(pending.tree_id)]
    if info then
        info.name = trimmed_name
        info.display_name = trimmed_name
    end

    if pending.target_type == "master_clip" then
        local clip = M.master_clip_map and M.master_clip_map[pending.target_id]
        if clip then
            clip.name = trimmed_name
        end
    elseif pending.target_type == "sequence" then
        local seq = M.sequence_map and M.sequence_map[pending.target_id]
        if seq then
            seq.name = trimmed_name
        end
    elseif pending.target_type == "bin" then
        local bin = M.bin_map and M.bin_map[pending.target_id]
        if bin then
            bin.name = trimmed_name
        end
    end

    if M.selected_item and M.selected_item.tree_id == pending.tree_id then
        M.selected_item.name = trimmed_name
        M.selected_item.display_name = trimmed_name
    end
    if M.selected_items then
        for _, item in ipairs(M.selected_items) do
            if item.tree_id == pending.tree_id then
                item.name = trimmed_name
                item.display_name = trimmed_name
            end
        end
    end

    if pending.target_type ~= "bin" then
        browser_state.update_selection(M.selected_items or {}, {
            master_lookup = M.master_clip_map,
            media_lookup = M.media_map,
            sequence_lookup = M.sequence_map,
            project_id = M.project_id
        })
    end

    local ok_state, timeline_state = pcall(require, 'ui.timeline.timeline_state')
    if ok_state and timeline_state then
        if pending.target_type == "master_clip" then
            if timeline_state.get_sequence_id and timeline_state.reload_clips then
                local active_sequence_id = timeline_state.get_sequence_id()
                if active_sequence_id and active_sequence_id ~= "" then
                    timeline_state.reload_clips(active_sequence_id)
                end
            end
        elseif pending.target_type == "sequence" then
            if timeline_state.reload_clips then
                timeline_state.reload_clips(pending.target_id)
            end
        end
    end

    pending.preview_name = nil
    M.pending_rename = nil
end

M._test_finalize_pending_rename = finalize_pending_rename

local function handle_tree_editor_closed(event)
    if not M.pending_rename then
        return
    end

    print(string.format("Rename close event: item=%s accepted=%s text=%s",
        tostring(event and event.item_id), tostring(event and event.accepted), tostring(event and event.text)))

    local pending = M.pending_rename
    if event and event.item_id and event.item_id ~= pending.tree_id then
        return
    end

    if event and event.accepted == false then
        if qt_constants.CONTROL.SET_TREE_ITEM_TEXT then
            qt_constants.CONTROL.SET_TREE_ITEM_TEXT(M.tree, pending.tree_id, pending.original_name or "", 0)
        end
        M.pending_rename = nil
        return
    end

    local new_text = (event and event.text) or pending.preview_name or pending.original_name
    M.ignore_tree_item_change = true
    finalize_pending_rename(new_text)
    M.ignore_tree_item_change = false
end

local function handle_tree_item_changed(event)
    if M.ignore_tree_item_change then
        return
    end

    local pending = M.pending_rename
    if not pending or type(event) ~= "table" then
        return
    end

    print(string.format("Rename change event: item=%s column=%s text=%s pending_tree=%s",
        tostring(event.item_id), tostring(event.column), tostring(event.text), tostring(pending.tree_id)))
    if event.item_id ~= pending.tree_id then
        return
    end

    if event.column and event.column ~= 0 then
        return
    end

    M.ignore_tree_item_change = true
    local new_name = trim(event.text or "")
    if new_name == "" then
        if qt_constants.CONTROL.SET_TREE_ITEM_TEXT then
            qt_constants.CONTROL.SET_TREE_ITEM_TEXT(M.tree, pending.tree_id, pending.original_name or "", 0)
        end
        M.ignore_tree_item_change = false
        return
    end

    if new_name == (pending.original_name or "") then
        M.ignore_tree_item_change = false
        return
    end

    pending.preview_name = new_name
    M.ignore_tree_item_change = false
end

M.item_lookup = {}
M.media_map = {}
M.master_clip_map = {}
M.sequence_map = {}
M.bin_map = {}
M.bin_tree_map = {}
M.bins = {}
M.selected_item = nil
M.selected_items = {}
M.pending_rename = nil
M.ignore_tree_item_change = false
M.project_id = nil
M.viewer_panel = nil
M.inspector_view = nil

local ACTIVATE_COMMAND = "ActivateBrowserSelection"

local function activate_item(item_info)
    if not item_info or type(item_info) ~= "table" then
        return false, "No browser item selected"
    end

    if item_info.type == "timeline" then
        if M.timeline_panel and M.timeline_panel.load_sequence then
            M.timeline_panel.load_sequence(item_info.id)
        else
            print("⚠️  Timeline panel not available")
        end

        if focus_manager and focus_manager.focus_panel then
            focus_manager.focus_panel("timeline")
        else
            focus_manager.set_focused_panel("timeline")
        end

        if M.viewer_panel then
            if M.viewer_panel.show_timeline then
                M.viewer_panel.show_timeline(item_info)
            elseif M.viewer_panel.clear then
                M.viewer_panel.clear()
            end
        end
        return true
    elseif item_info.type == "master_clip" then
        local clip = item_info.clip_id and M.master_clip_map[item_info.clip_id]
            or (item_info.media_id and M.master_clip_map[item_info.media_id])
        if not clip then
            return false, "Master clip metadata missing"
        end

        local media = clip.media or (clip.media_id and M.media_map[clip.media_id]) or {}

        if M.viewer_panel and M.viewer_panel.show_source_clip then
            local viewer_payload = {
                id = clip.clip_id,
                clip_id = clip.clip_id,
                media_id = clip.media_id,
                name = clip.name or media.name or clip.clip_id,
                duration = clip.duration or media.duration,
                frame_rate = clip.frame_rate or media.frame_rate,
                width = clip.width or media.width,
                height = clip.height or media.height,
                codec = clip.codec or media.codec,
                file_path = clip.file_path or media.file_path,
                metadata = media.metadata,
                offline = clip.offline,
            }
            M.viewer_panel.show_source_clip(viewer_payload)
        end
        if focus_manager and focus_manager.focus_panel then
            focus_manager.focus_panel("viewer")
        else
            focus_manager.set_focused_panel("viewer")
        end
        return true
    end

    return false, "Browser item type not supported"
end

local function store_tree_item(tree, tree_id, info)
    if not tree_id or not info then
        return
    end
    info.tree_id = tree_id
    local ok, encoded = pcall(qt_json_encode, info)
    if ok and qt_constants.CONTROL.SET_TREE_ITEM_DATA then
        qt_constants.CONTROL.SET_TREE_ITEM_DATA(tree, tree_id, encoded)
    end
    M.item_lookup[tostring(tree_id)] = info
end

local function format_duration(duration_ms, frame_rate)
    if not duration_ms or duration_ms == 0 then
        return "--:--"
    end

    local rate = frame_rate or frame_utils.default_frame_rate
    local ok, formatted = pcall(frame_utils.format_timecode, duration_ms, rate)
    if ok and formatted then
        return formatted
    end

    local total_seconds = math.floor(duration_ms / 1000)
    local hours = math.floor(total_seconds / 3600)
    local minutes = math.floor((total_seconds % 3600) / 60)
    local seconds = total_seconds % 60

    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds)
    else
        return string.format("%d:%02d", minutes, seconds)
    end
end

local function format_date(timestamp)
    if not timestamp or timestamp == 0 then
        return ""
    end
    return os.date("%b %d %Y", timestamp)
end

local function resolve_tree_item(entry)
    if not entry then
        return nil
    end

    if entry.data and entry.data ~= "" then
        local ok, decoded = pcall(qt_json_decode, entry.data)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end

    if entry.item_id and M.item_lookup then
        return M.item_lookup[tostring(entry.item_id)]
    end

    return nil
end

local function populate_tree()
    if not M.tree then
        return
    end

    local previous_selection = nil
    if M.selected_items and #M.selected_items > 0 then
        previous_selection = {}
        for _, item in ipairs(M.selected_items) do
            if item.type == "timeline" and item.id then
                table.insert(previous_selection, {type = "timeline", id = item.id})
            elseif item.type == "master_clip" and item.clip_id then
                table.insert(previous_selection, {type = "master_clip", clip_id = item.clip_id})
            end
        end
    end

    qt_constants.CONTROL.CLEAR_TREE(M.tree)
    M.item_lookup = {}
    M.media_map = {}
    M.master_clip_map = {}
    M.sequence_map = {}
    M.bin_map = {}
    M.bin_tree_map = {}
    M.bins = {}
    M.selected_item = nil
    M.selected_items = {}
    M.pending_rename = nil
    M.ignore_tree_item_change = false

    local project_id = M.project_id or db.get_current_project_id()
    M.project_id = project_id

    local bins = db.load_bins()
    M.bins = bins
    local media_items = db.load_media()
    local master_clips = db.load_master_clips(project_id)
    local sequences = db.load_sequences(project_id)

    M.media_items = media_items
    M.master_clips = master_clips
    for _, media in ipairs(media_items) do
        M.media_map[media.id] = media
    end
    for _, clip in ipairs(master_clips) do
        if clip.media and clip.media.id and not M.media_map[clip.media.id] then
            M.media_map[clip.media.id] = clip.media
        elseif clip.media_id and M.media_map[clip.media_id] and not clip.media then
            clip.media = M.media_map[clip.media_id]
        end
        M.master_clip_map[clip.clip_id] = clip
    end

    local bin_tree_map = {}

    local function build_bin_path(bin)
        local parts = {}
        local current = bin
        while current do
            table.insert(parts, 1, current.name)
            if current.parent_id then
                local parent = nil
                for _, candidate in ipairs(bins) do
                    if candidate.id == current.parent_id then
                        parent = candidate
                        break
                    end
                end
                current = parent
            else
                current = nil
            end
        end
        return table.concat(parts, "/")
    end

    local bin_path_lookup = {}
    for _, bin in ipairs(bins) do
        bin_path_lookup[build_bin_path(bin)] = bin.id
        M.bin_map[bin.id] = {
            id = bin.id,
            name = bin.name,
            parent_id = bin.parent_id
        }
    end

    local function add_bin(bin, parent_id)
        local display_name = "▶ " .. bin.name
        local tree_id
        if parent_id then
            tree_id = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(M.tree, parent_id, {display_name, "", "", "", "", ""})
        else
            tree_id = qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, {display_name, "", "", "", "", ""})
        end
        store_tree_item(M.tree, tree_id, {
            type = "bin",
            id = bin.id,
            name = bin.name,
            parent_id = bin.parent_id
        })
        if qt_constants.CONTROL.SET_TREE_ITEM_ICON then
            qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, tree_id, "bin")
        end
        bin_tree_map[bin.id] = tree_id
        if M.bin_map[bin.id] then
            M.bin_map[bin.id].tree_id = tree_id
        end
        return tree_id
    end

    -- Root sequences
    for _, sequence in ipairs(sequences) do
        if not sequence.kind or sequence.kind == "timeline" then
        local duration_str = format_duration(sequence.duration, sequence.frame_rate)
        local resolution_str = (sequence.width and sequence.height and sequence.width > 0)
            and string.format("%dx%d", sequence.width, sequence.height)
            or ""
        local fps_str = (sequence.frame_rate and sequence.frame_rate > 0)
            and string.format("%.2f", sequence.frame_rate)
            or ""

        local tree_id = qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, {
            sequence.name,
            duration_str,
            resolution_str,
            fps_str,
            "Timeline",
            ""
        })

        local sequence_info = {
            type = "timeline",
            id = sequence.id,
            name = sequence.name,
            frame_rate = sequence.frame_rate,
            width = sequence.width,
            height = sequence.height,
            duration = sequence.duration,
            tree_id = tree_id
        }

        store_tree_item(M.tree, tree_id, sequence_info)
        M.sequence_map[sequence.id] = sequence_info
        if qt_constants.CONTROL.SET_TREE_ITEM_ICON then
            qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, tree_id, "timeline")
        end
        end
    end

    -- Root bins
    for _, bin in ipairs(bins) do
        if not bin.parent_id then
            add_bin(bin, nil)
        end
    end

    -- Nested bins
    for _, bin in ipairs(bins) do
        if bin.parent_id and bin_tree_map[bin.parent_id] then
            add_bin(bin, bin_tree_map[bin.parent_id])
        end
    end

    local function get_bin_tag(media)
        if media.tags then
            for _, tag in ipairs(media.tags) do
                if tag.namespace == "bin" then
                    return tag.tag_path
                end
            end
        end
        return nil
    end

    local function add_master_clip_item(parent_id, clip)
        local media = clip.media or (clip.media_id and M.media_map[clip.media_id]) or {}
        local duration_ms = clip.duration or media.duration
        local duration_str = format_duration(duration_ms, clip.frame_rate or (media and media.frame_rate))
        local display_width = clip.width or media.width
        local display_height = clip.height or media.height
        local display_fps = clip.frame_rate or media.frame_rate
        local resolution_str = (display_width and display_height and display_width > 0)
            and string.format("%dx%d", display_width, display_height)
            or ""
        local fps_str = (display_fps and display_fps > 0)
            and string.format("%.2f", display_fps)
            or ""
        local codec_str = clip.codec or media.codec or ""
        local date_str = format_date(clip.modified_at or clip.created_at or media.modified_at or media.created_at)

        local columns = {
            clip.name or media.name or clip.clip_id,
            duration_str,
            resolution_str,
            fps_str,
            codec_str,
            date_str
        }

        local tree_id
        if parent_id then
            tree_id = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(M.tree, parent_id, columns)
        else
            tree_id = qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, columns)
        end

        store_tree_item(M.tree, tree_id, {
            type = "master_clip",
            clip_id = clip.clip_id,
            media_id = clip.media_id,
            sequence_id = clip.source_sequence_id,
            bin_id = clip.bin_id,
            name = clip.name or media.name or clip.clip_id,
            file_path = clip.file_path or media.file_path,
            duration = duration_ms,
            frame_rate = display_fps,
            width = display_width,
            height = display_height,
            codec = codec_str,
            metadata = media.metadata,
            offline = clip.offline
        })
        if qt_constants.CONTROL.SET_TREE_ITEM_ICON then
            local icon = clip.offline and "clip_offline" or "clip"
            qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, tree_id, icon)
        end
        clip.tree_id = tree_id
    end

    -- Root master clips
    for _, clip in ipairs(master_clips) do
        clip.bin_id = nil
        local media = clip.media or (clip.media_id and M.media_map[clip.media_id]) or {}
        local bin_tag = get_bin_tag(media)
        if not bin_tag then
            add_master_clip_item(nil, clip)
        end
    end

    -- Master clips inside bins
    for _, clip in ipairs(master_clips) do
        local media = clip.media or (clip.media_id and M.media_map[clip.media_id]) or {}
        local bin_tag = get_bin_tag(media)
        if bin_tag then
            local bin_id = bin_path_lookup[bin_tag]
            local parent_tree = bin_id and bin_tree_map[bin_id]
            clip.bin_id = bin_id
            if parent_tree then
                add_master_clip_item(parent_tree, clip)
            else
                add_master_clip_item(nil, clip)
            end
        end
    end

    local function restore_previous_selection_from_cache(previous)
        if not previous or #previous == 0 then
            browser_state.clear_selection()
            return
        end

        local matches = {}
        for _, prev in ipairs(previous) do
            if prev.type == "timeline" then
                local seq = M.sequence_map[prev.id]
                if seq and seq.tree_id then
                    local info = M.item_lookup and M.item_lookup[tostring(seq.tree_id)]
                    if info then
                        table.insert(matches, {tree_id = seq.tree_id, info = info})
                    end
                end
            elseif prev.type == "master_clip" then
                local clip = M.master_clip_map[prev.clip_id]
                if clip and clip.tree_id then
                    local info = M.item_lookup and M.item_lookup[tostring(clip.tree_id)]
                    if info then
                        table.insert(matches, {tree_id = clip.tree_id, info = info})
                    end
                end
            elseif prev.type == "bin" then
                local bin = M.bin_map[prev.id]
                if bin and bin.tree_id then
                    local info = M.item_lookup and M.item_lookup[tostring(bin.tree_id)]
                    if info then
                        table.insert(matches, {tree_id = bin.tree_id, info = info})
                    end
                end
            end
        end

        if #matches == 0 then
            browser_state.clear_selection()
            return
        end

        if qt_constants.CONTROL.SET_TREE_CURRENT_ITEM then
            is_restoring_selection = true
            local clear_previous = true
            for _, match in ipairs(matches) do
                qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(M.tree, match.tree_id, true, clear_previous)
                clear_previous = false
            end
            is_restoring_selection = false

            if not M.selected_items or #M.selected_items == 0 then
                local collected = {}
                for _, match in ipairs(matches) do
                    table.insert(collected, match.info)
                end
                M.selected_items = collected
                M.selected_item = collected[1]
                browser_state.update_selection(collected, {
                    master_lookup = M.master_clip_map,
                    media_lookup = M.media_map,
                    sequence_lookup = M.sequence_map,
                    project_id = M.project_id
                })
            end
        else
            local collected = {}
            for _, match in ipairs(matches) do
                table.insert(collected, match.info)
            end
            M.selected_items = collected
            M.selected_item = collected[1]
            browser_state.update_selection(collected, {
                master_lookup = M.master_clip_map,
                media_lookup = M.media_map,
                sequence_lookup = M.sequence_map,
                project_id = M.project_id
            })
        end
    end

    restore_previous_selection_from_cache(previous_selection)

    M.bin_tree_map = bin_tree_map
end

-- Create project browser widget
function M.create()
    -- Create container
    local container = qt_constants.WIDGET.CREATE()
    local layout = qt_constants.LAYOUT.CREATE_VBOX()

    -- Set layout spacing
    qt_constants.CONTROL.SET_LAYOUT_SPACING(layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(layout, 0)

    -- Create header with project name tab
    local header = qt_constants.WIDGET.CREATE()
    local header_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.LAYOUT.SET_ON_WIDGET(header, header_layout)

    qt_constants.PROPERTIES.SET_STYLE(header, [[
        QWidget {
            background: #2b2b2b;
            border-bottom: 1px solid #1a1a1a;
        }
    ]])

    -- Project name tab (active) - shows current project or "Unsaved"
    local project_tab = qt_constants.WIDGET.CREATE_LABEL("  Unsaved  ")
    qt_constants.PROPERTIES.SET_STYLE(project_tab, [[
        QLabel {
            background: #3a3a3a;
            color: white;
            padding: 6px 12px;
            font-size: 11px;
            border-top: 2px solid #4a90e2;
        }
    ]])
    qt_constants.LAYOUT.ADD_WIDGET(header_layout, project_tab)

    qt_constants.LAYOUT.ADD_STRETCH(header_layout, 1)

    -- Add "Insert to Timeline" button
    local insert_btn = qt_constants.WIDGET.CREATE_BUTTON("Insert to Timeline")
    qt_constants.PROPERTIES.SET_STYLE(insert_btn, [[
        QPushButton {
            background: #4a4a4a;
            color: white;
            border: 1px solid #555;
            padding: 4px 8px;
            font-size: 11px;
        }
        QPushButton:hover {
            background: #5a5a5a;
        }
        QPushButton:pressed {
            background: #3a3a3a;
        }
    ]])
    qt_constants.LAYOUT.ADD_WIDGET(header_layout, insert_btn)

    qt_constants.LAYOUT.ADD_WIDGET(layout, header)

    -- Create tree widget for media library (Resolve style)
    local tree = qt_constants.WIDGET.CREATE_TREE()
    qt_constants.PROPERTIES.SET_STYLE(tree, [[
        QTreeWidget {
            background: #262626;
            color: #cccccc;
            border: none;
            font-size: ]] .. ui_constants.FONTS.DEFAULT_FONT_SIZE .. [[;
            outline: none;
        }
        QTreeWidget::item {
            padding: 2px;
            padding-left: 4px;
            height: 22px;
        }
        QTreeWidget::item:selected {
            background: #4a4a4a;
            color: white;
        }
        QTreeWidget::item:hover {
            background: #333333;
        }
        QTreeWidget::branch {
            background: #262626;
            border: none;
        }
        QTreeWidget::branch:has-children {
            background: #262626;
            border: none;
            image: none;
        }
        QTreeWidget::branch:selected {
            background: #262626;
        }
        QTreeWidget::branch:has-children:selected {
            background: #262626;
        }
        QHeaderView::section {
            background: #2b2b2b;
            color: #888;
            padding: 4px;
            border: none;
            border-right: 1px solid #1a1a1a;
            font-size: ]] .. ui_constants.FONTS.DEFAULT_FONT_SIZE .. [[;
            font-weight: normal;
        }
    ]])

    -- Set tree columns (Professional NLE style: Name, Duration, Resolution, FPS, Codec, Date Modified)
    qt_constants.CONTROL.SET_TREE_HEADERS(tree, {"Clip Name", "Duration", "Resolution", "FPS", "Codec", "Date Modified"})
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 0, 180)  -- Clip Name
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 1, 80)   -- Duration
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 2, 80)   -- Resolution
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 3, 50)   -- FPS
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 4, 60)   -- Codec
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(tree, 5, 100)  -- Date Modified

    -- Set minimal indentation like Premiere (just enough for nested items)
    qt_constants.CONTROL.SET_TREE_INDENTATION(tree, 12)

    if qt_constants.CONTROL.SET_TREE_SELECTION_MODE then
        qt_constants.CONTROL.SET_TREE_SELECTION_MODE(tree, "extended")
    end

    M.tree = tree
    M.project_id = db.get_current_project_id()
    ensure_command_listener()
    populate_tree()

    local selection_handler = register_handler(function(event)
        local collected = {}

        if event and type(event.items) == "table" then
            for _, entry in ipairs(event.items) do
                local info = resolve_tree_item(entry)
                if info then
                    table.insert(collected, info)
                end
            end
        end

        if #collected == 0 then
            local fallback = resolve_tree_item(event)
            if fallback then
                table.insert(collected, fallback)
            end
        end

        M.selected_items = collected
        M.selected_item = collected[1]

        if M.pending_rename and qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE then
            local rename_tree_id = M.pending_rename.tree_id
            local still_selected = false
            for _, info in ipairs(collected) do
                if info.tree_id == rename_tree_id then
                    still_selected = true
                    break
                end
            end

            if not still_selected then
                qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE(M.tree, rename_tree_id, false)
                M.pending_rename = nil
            end
        end

        browser_state.update_selection(collected, {
            master_lookup = M.master_clip_map,
            media_lookup = M.media_map,
            sequence_lookup = M.sequence_map,
            project_id = M.project_id
        })

        if not is_restoring_selection then
            if focus_manager and focus_manager.focus_panel then
                focus_manager.focus_panel("project_browser")
            else
                focus_manager.set_focused_panel("project_browser")
            end
        end
    end)
    if qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER then
        qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER(tree, selection_handler)
    end

    local changed_handler = register_handler(function(event)
        handle_tree_item_changed(event)
    end)
    if qt_constants.CONTROL.SET_TREE_ITEM_CHANGED_HANDLER then
        qt_constants.CONTROL.SET_TREE_ITEM_CHANGED_HANDLER(tree, changed_handler)
    end

    local close_handler = register_handler(function(event)
        handle_tree_editor_closed(event)
    end)
    if qt_constants.CONTROL.SET_TREE_CLOSE_EDITOR_HANDLER then
        qt_constants.CONTROL.SET_TREE_CLOSE_EDITOR_HANDLER(tree, close_handler)
    end

    local double_click_handler = register_handler(function(event)
        if not event then
            return
        end

        local item_info = resolve_tree_item(event)
        if not item_info and event and type(event.items) == "table" then
            item_info = resolve_tree_item(event.items[1])
        end

        if not item_info or type(item_info) ~= "table" then
            return
        end

        M.selected_item = item_info
        local result = command_manager.execute(ACTIVATE_COMMAND)
        if not result.success then
            print(string.format("⚠️  ActivateBrowserSelection failed: %s", result.error_message or "unknown error"))
        end
    end)
    if qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER then
        qt_constants.CONTROL.SET_TREE_DOUBLE_CLICK_HANDLER(tree, double_click_handler)
    end

    qt_constants.LAYOUT.ADD_WIDGET(layout, tree)

    -- Set layout on container
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)

    -- Store references for later access
    M.tree = tree
    M.insert_button = insert_btn
    M.container = container

    local media_count = M.master_clips and #M.master_clips or 0
    local sequence_count = 0
    if M.item_lookup then
        for _, info in pairs(M.item_lookup) do
            if info.type == "timeline" then
                sequence_count = sequence_count + 1
            end
        end
    end
    print(string.format("✅ Project browser created with %d media item(s) and %d timeline(s)", media_count, sequence_count))

    return container
end

function M.get_focus_widgets()
    local widgets = {}
    if M.tree then
        table.insert(widgets, M.tree)
    end
    return widgets
end

-- Set timeline panel reference (called by layout.lua after both are created)
function M.set_timeline_panel(timeline_panel_mod)
    M.timeline_panel = timeline_panel_mod

    if M.insert_button then
        _G.project_browser_insert_handler = function()
            M.insert_selected_to_timeline()
        end
        qt_set_button_click_handler(M.insert_button, "project_browser_insert_handler")
    end
end

function M.set_viewer_panel(viewer_panel_mod)
    M.viewer_panel = viewer_panel_mod
end

function M.set_inspector(inspector_view)
    M.inspector_view = inspector_view
end

-- Get selected media item
function M.get_selected_master_clip()
    if not M.selected_items or #M.selected_items == 0 then
        return nil
    end
    local first = M.selected_items[1]
    if not first or first.type ~= "master_clip" then
        return nil
    end
    return first.clip_id and M.master_clip_map[first.clip_id]
end

function M.get_selected_media()
    return M.get_selected_master_clip()
end

-- Refresh media list from database
function M.refresh()
    ensure_command_listener()
    populate_tree()
end

function M.insert_selected_to_timeline()
    if not M.timeline_panel then
        print("⚠️  Timeline panel not available")
        return
    end

    local clip = M.get_selected_master_clip()
    if not clip then
        print("⚠️  No media item selected")
        return
    end
    local media = clip.media or (clip.media_id and M.media_map[clip.media_id]) or {}

    local timeline_state_module = M.timeline_panel.get_state()
    local sequence_id = timeline_state_module.get_sequence_id and timeline_state_module.get_sequence_id() or "default_sequence"
    local project_id = timeline_state_module.get_project_id and timeline_state_module.get_project_id() or "default_project"
    local track_id = timeline_state_module.get_default_video_track_id and timeline_state_module.get_default_video_track_id() or nil
    if not track_id or track_id == "" then
        print("❌ No video track found in active sequence")
        return
    end

    local Command = require("command")

    local insert_time = timeline_state_module.get_playhead_time and timeline_state_module.get_playhead_time() or 0
    local source_in = clip.source_in or 0
    local source_out = clip.source_out or clip.duration or media.duration or 0
    local duration = source_out - source_in
    if duration <= 0 then
        print("⚠️  Media duration is invalid")
        return
    end

    local cmd = Command.create("Insert", project_id)
    cmd:set_parameter("sequence_id", sequence_id)
    cmd:set_parameter("track_id", track_id)
    cmd:set_parameter("master_clip_id", clip.clip_id)
    cmd:set_parameter("media_id", clip.media_id or media.id)
    cmd:set_parameter("insert_time", insert_time)
    cmd:set_parameter("duration", duration)
    cmd:set_parameter("source_in", source_in)
    cmd:set_parameter("source_out", source_out)
    cmd:set_parameter("project_id", clip.project_id or project_id)

    local success, result = pcall(function()
        return command_manager.execute(cmd)
    end)

    if success and result and result.success then
        print(string.format("✅ Media inserted to timeline: %s", media.name or media.file_name))
        if focus_manager and focus_manager.focus_panel then
            focus_manager.focus_panel("timeline")
        else
            focus_manager.set_focused_panel("timeline")
        end
    else
        print(string.format("❌ Failed to insert: %s", result and result.error_message or "unknown"))
    end
end

function M.delete_selected_items()
    if not M.selected_items or #M.selected_items == 0 then
        return false
    end

    local Command = require("command")
    local deleted = 0
    local clip_failures = 0
    local sequence_failures = 0

    local handled_sequences = {}
    for _, item in ipairs(M.selected_items) do
        if item.type == "master_clip" and item.clip_id then
            local clip = M.master_clip_map[item.clip_id]
            if clip then
                local project_id = clip.project_id or M.project_id or "default_project"
                local cmd = Command.create("DeleteMasterClip", project_id)
                cmd:set_parameter("master_clip_id", clip.clip_id)
                local result = command_manager.execute(cmd)
                if result and result.success then
                    deleted = deleted + 1
                else
                    print(string.format("⚠️  Delete master clip failed: %s", result and result.error_message or "unknown error"))
                    clip_failures = clip_failures + 1
                end
            end
        elseif item.type == "timeline" and item.id then
            local sequence_id = item.id
            if not handled_sequences[sequence_id] then
                handled_sequences[sequence_id] = true
                if sequence_id == "default_sequence" then
                    sequence_failures = sequence_failures + 1
                    print("⚠️  Delete sequence default_sequence skipped: primary timeline cannot be removed")
                    goto continue_delete_loop
                end

                local project_id = M.project_id or "default_project"
                local cmd = Command.create("DeleteSequence", project_id)
                cmd:set_parameter("sequence_id", sequence_id)
                local result = command_manager.execute(cmd)
                if result and result.success then
                    deleted = deleted + 1
                else
                    sequence_failures = sequence_failures + 1
                    print(string.format("⚠️  Delete sequence %s failed: %s", tostring(sequence_id), result and result.error_message or "unknown error"))
                end
                ::continue_delete_loop::
            end
        end
    end

    if deleted > 0 then
        M.refresh()
        return true
    end

    if clip_failures > 0 or sequence_failures > 0 then
        return false
    end

    return false
end

function M.activate_selection()
    if not M.selected_item then
        return false, "No selection"
    end
    return activate_item(M.selected_item)
end

function M.get_selected_bin()
    if not M.selected_item or M.selected_item.type ~= "bin" then
        return nil
    end
    local bin = M.bin_map and M.bin_map[M.selected_item.id]
    if bin then
        return bin
    end
    return {
        id = M.selected_item.id,
        name = M.selected_item.name,
        parent_id = M.selected_item.parent_id
    }
end

local function expand_bin_chain(bin_id)
    if not bin_id then
        return
    end
    if not qt_constants or not qt_constants.CONTROL or not qt_constants.CONTROL.SET_TREE_ITEM_EXPANDED then
        return
    end
    local current = bin_id
    while current do
        local bin_info = M.bin_map and M.bin_map[current]
        if not bin_info then
            break
        end
        if bin_info.tree_id then
            qt_constants.CONTROL.SET_TREE_ITEM_EXPANDED(M.tree, bin_info.tree_id, true)
        end
        current = bin_info.parent_id
    end
end

local function update_selection_state(info)
    if not info then
        return
    end
    M.selected_item = info
    M.selected_items = {info}
    browser_state.update_selection({info}, {
        master_lookup = M.master_clip_map,
        media_lookup = M.media_map,
        sequence_lookup = M.sequence_map,
        project_id = M.project_id
    })
end

function M.focus_master_clip(master_clip_id, opts)
    opts = opts or {}
    if not master_clip_id or master_clip_id == "" then
        return false, "Invalid master clip id"
    end

    local clip = M.master_clip_map and M.master_clip_map[master_clip_id]
    if not clip then
        return false, "Master clip not found"
    end

    if clip.bin_id then
        expand_bin_chain(clip.bin_id)
    end

    if not clip.tree_id then
        return false, "Master clip not present in browser"
    end

    if qt_constants.CONTROL.SET_TREE_CURRENT_ITEM then
        is_restoring_selection = true
        qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(M.tree, clip.tree_id, true, true)
        is_restoring_selection = false
    end

    local info = M.item_lookup and M.item_lookup[tostring(clip.tree_id)]
    if not info then
        return false, "Master clip metadata unavailable"
    end

    update_selection_state(info)

    if not opts.skip_focus then
        if focus_manager and focus_manager.focus_panel then
            focus_manager.focus_panel("project_browser")
        else
            focus_manager.set_focused_panel("project_browser")
        end
    end

    if not opts.skip_activate then
        activate_item(info)
    end

    return true
end

function M.focus_bin(bin_id, opts)
    opts = opts or {}
    if not bin_id or bin_id == "" then
        M.selected_item = nil
        M.selected_items = {}
        browser_state.clear_selection()
        return true
    end

    local bin = M.bin_map and M.bin_map[bin_id]
    if not bin then
        return false, "Bin not found"
    end

    expand_bin_chain(bin_id)

    if not bin.tree_id then
        return false, "Bin not present in browser"
    end

    if qt_constants.CONTROL.SET_TREE_CURRENT_ITEM then
        is_restoring_selection = true
        qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(M.tree, bin.tree_id, true, true)
        is_restoring_selection = false
    end

    local info = M.item_lookup and M.item_lookup[tostring(bin.tree_id)]
    if not info then
        return false, "Bin metadata unavailable"
    end

    update_selection_state(info)

    if not opts.skip_focus then
        if focus_manager and focus_manager.focus_panel then
            focus_manager.focus_panel("project_browser")
        else
            focus_manager.set_focused_panel("project_browser")
        end
    end

    return true
end

function M.start_inline_rename()
    if not M.tree or not M.selected_item then
        print("⚠️  Rename: No selection to rename")
        return false
    end

    if M.pending_rename and qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE then
        qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE(M.tree, M.pending_rename.tree_id, false)
    end

    local item = M.selected_item
    local target_type = nil
    local target_id = nil
    local tree_id = item.tree_id
    local current_name = item.name or item.display_name or ""

    if item.type == "master_clip" then
        target_type = "master_clip"
        target_id = item.clip_id
        local clip = target_id and M.master_clip_map and M.master_clip_map[target_id]
        if clip then
            tree_id = clip.tree_id or tree_id
            current_name = clip.name or current_name
        end
    elseif item.type == "timeline" then
        target_type = "sequence"
        target_id = item.id
        local seq = target_id and M.sequence_map and M.sequence_map[target_id]
        if seq then
            tree_id = seq.tree_id or tree_id
            current_name = seq.name or current_name
        end
    elseif item.type == "bin" then
        target_type = "bin"
        target_id = item.id
        local bin = target_id and M.bin_map and M.bin_map[target_id]
        if bin then
            tree_id = bin.tree_id or tree_id
            current_name = bin.name or current_name
        end
    else
        print(string.format("⚠️  Rename: Unsupported selection type '%s'", tostring(item.type)))
        return false
    end

    if not tree_id or not target_id then
        print("⚠️  Rename: Unable to locate selected item in tree")
        return false
    end

    M.pending_rename = {
        tree_id = tree_id,
        target_type = target_type,
        target_id = target_id,
        original_name = current_name
    }

    local editable_ok = false
    if qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE then
        editable_ok = qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE(M.tree, tree_id, true)
        print(string.format("Rename: SET_TREE_ITEM_EDITABLE result=%s", tostring(editable_ok)))
    else
        print("Rename: SET_TREE_ITEM_EDITABLE missing")
    end

    local edit_started = false
    if qt_constants.CONTROL.EDIT_TREE_ITEM then
        edit_started = qt_constants.CONTROL.EDIT_TREE_ITEM(M.tree, tree_id, 0)
        print(string.format("Rename: EDIT_TREE_ITEM result=%s", tostring(edit_started)))
    else
        print("Rename: EDIT_TREE_ITEM missing")
    end
    return edit_started
end

function M.focus_sequence(sequence_id, opts)
    if not sequence_id or sequence_id == "" then
        return false, "Invalid sequence id"
    end

    local sequence_info = M.sequence_map and M.sequence_map[sequence_id]
    if not sequence_info then
        return false, "Sequence not found"
    end

    M.selected_item = sequence_info
    M.selected_items = {sequence_info}

    browser_state.update_selection({sequence_info}, {
        media_lookup = M.media_map,
        sequence_lookup = M.sequence_map
    })

    if not opts or not opts.skip_activate then
        activate_item(sequence_info)
    end

    return true
end

command_manager.register_executor(ACTIVATE_COMMAND, function()
    local ok, err = M.activate_selection()
    if not ok and err then
        print(string.format("⚠️  %s", err))
    end
    return ok and true or false
end)

command_scope.register(ACTIVATE_COMMAND, {scope = "panel", panel_id = "project_browser"})

return M
