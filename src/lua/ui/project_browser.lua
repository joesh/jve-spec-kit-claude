-- Project Browser - Media library and bin management
-- Shows imported media files, allows drag-to-timeline
-- Mimics DaVinci Resolve Media Pool style

local M = {}
local db = require("core.database")
local tag_service = require("core.tag_service")
local ui_constants = require("core.ui_constants")
local focus_manager = require("ui.focus_manager")
local command_manager = require("core.command_manager")
local command_scope = require("core.command_scope")
local Command = require("command")
local browser_state = require("ui.project_browser.browser_state")
local frame_utils = require("core.frame_utils")
local keymap = require("ui.project_browser.keymap")
local qt_constants = require("core.qt_constants")
local profile_scope = require("core.profile_scope")

local handler_seq = 0

local function selection_context()
    return {
        master_lookup = M.master_clip_map,
        media_lookup = M.media_map,
        sequence_lookup = M.sequence_map,
        project_id = M.project_id,
        bin_lookup = M.media_bin_map
    }
end

local REFRESH_COMMANDS = {
    ImportMedia = true,
    ImportFCP7XML = true,
    DeleteMasterClip = true,
    DeleteSequence = true,
    DuplicateMasterClip = true,
    ImportResolveProject = true,
    ImportResolveDatabase = true,
    RenameItem = true,
    CreateSequence = true,
}

local command_listener_registered = false
local is_restoring_selection = false
local show_browser_context_menu  -- forward declaration for tree context menu handler
local handle_tree_key_event      -- forward declaration for key handler

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
        command_manager.add_listener(profile_scope.wrap("project_browser.command_listener", handle_command_event))
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

local function lookup_item_by_tree_id(tree_id)
    if not tree_id or not M.item_lookup then
        return nil
    end
    return M.item_lookup[tostring(tree_id)]
end

local function is_descendant(potential_parent_id, target_id)
    if not potential_parent_id or not target_id then
        return false
    end
    local current = potential_parent_id
    while current do
        if current == target_id then
            return true
        end
        local bin = M.bin_map and M.bin_map[current]
        current = bin and bin.parent_id or nil
    end
    return false
end

local function set_bin_parent(bin_id, new_parent_id)
    if not bin_id then
        return false
    end

    local changed = false
    if M.bins then
        for _, bin in ipairs(M.bins) do
            if bin.id == bin_id then
                if bin.parent_id ~= new_parent_id then
                    bin.parent_id = new_parent_id
                    changed = true
                end
                break
            end
        end
    end

    if M.bin_map and M.bin_map[bin_id] then
        M.bin_map[bin_id].parent_id = new_parent_id
    end

    return changed
end

local function defer_to_ui(callback)
    if type(qt_create_single_shot_timer) == "function" then
        qt_create_single_shot_timer(0, function()
            callback()
        end)
    else
        callback()
    end
end

local function collect_name_lookup(map)
    local lookup = {}
    if map then
        for _, entry in pairs(map) do
            local name = entry and entry.name
            if name and name ~= "" then
                lookup[name:lower()] = true
            end
        end
    end
    return lookup
end

local function focus_tree_widget()
    if qt_set_focus and M.tree then
        pcall(qt_set_focus, M.tree)
    end
end

local function generate_sequential_label(prefix, lookup)
    local suffix = 1
    while true do
        local candidate = string.format("%s %d", prefix, suffix)
        if not lookup[candidate:lower()] then
            return candidate
        end
        suffix = suffix + 1
    end
end

local function current_project_id()
    local ok, value = pcall(function()
        return M.project_id or db.get_current_project_id()
    end)
    if ok and value and value ~= "" then
        return value
    end
    return "default_project"
end

local function sequence_defaults()
    local defaults = {
        frame_rate = 30.0,
        width = 1920,
        height = 1080
    }

    local timeline_panel = M.timeline_panel
    local timeline_state_module = timeline_panel and timeline_panel.get_state and timeline_panel.get_state()
    local sequence_id = timeline_state_module and timeline_state_module.get_sequence_id and timeline_state_module.get_sequence_id()
    if sequence_id and sequence_id ~= "" then
        local ok, record = pcall(db.load_sequence_record, sequence_id)
        if ok and record then
            defaults.frame_rate = record.frame_rate or defaults.frame_rate
            defaults.width = record.width or defaults.width
            defaults.height = record.height or defaults.height
        end
    end

    return defaults
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
M.media_bin_map = {}
M.selected_item = nil
M.selected_items = {}
M.pending_rename = nil
M.ignore_tree_item_change = false
M.project_id = nil
M.viewer_panel = nil
M.inspector_view = nil
M.project_title_widget = nil
M.pending_project_title = nil

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
    elseif item_info.type == "bin" then
        if item_info.id then
            M.focus_bin(item_info.id, {
                skip_focus = false,
                skip_activate = true,
                skip_expand = true
            })
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

local function apply_single_selection(info)
    if not info then
        return
    end

    local collected = {info}
    M.selected_items = collected
    M.selected_item = info
    browser_state.update_selection(collected, {
        master_lookup = M.master_clip_map,
        media_lookup = M.media_map,
        sequence_lookup = M.sequence_map,
        project_id = M.project_id
    })
end

local function populate_tree()
    if not M.tree then
        return
    end

    local function record_previous_selection(target, item)
        if not item then
            return
        end
        if item.type == "timeline" and item.id then
            table.insert(target, {type = "timeline", id = item.id})
        elseif item.type == "master_clip" and item.clip_id then
            table.insert(target, {type = "master_clip", clip_id = item.clip_id})
        elseif item.type == "bin" and item.id then
            table.insert(target, {type = "bin", id = item.id})
        end
    end

    local previous_selection = nil
    if M.selected_items and #M.selected_items > 0 then
        previous_selection = {}
        for _, item in ipairs(M.selected_items) do
            record_previous_selection(previous_selection, item)
        end
    elseif M.selected_item then
        previous_selection = {}
        record_previous_selection(previous_selection, M.selected_item)
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

    local settings = db.get_project_settings(M.project_id)
    M.media_bin_map = tag_service.list_master_clip_assignments(M.project_id)

    local bins = tag_service.list(project_id)
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
    local bin_lookup = {}
    for _, bin in ipairs(bins) do
        if bin.id then
            bin_lookup[bin.id] = bin
        end
    end

    local bin_path_cache = {}
    local function build_bin_path(bin)
        if not bin or not bin.id then
            return nil
        end
        if bin_path_cache[bin.id] then
            return bin_path_cache[bin.id]
        end

        local parent_id = bin.parent_id
        local path = bin.name
        if parent_id and parent_id ~= "" then
            local parent = bin_lookup[parent_id]
            local parent_path = parent and build_bin_path(parent) or nil
            if parent_path and parent_path ~= "" then
                path = parent_path .. "/" .. bin.name
            else
                bin.parent_id = nil
            end
        else
            bin.parent_id = nil
        end

        bin_path_cache[bin.id] = path
        return path
    end

    local bin_path_lookup = {}
    for _, bin in ipairs(bins) do
        local path = build_bin_path(bin)
        if path then
            bin_path_lookup[path] = bin.id
        end
        M.bin_map[bin.id] = {
            id = bin.id,
            name = bin.name,
            parent_id = bin.parent_id
        }
    end

    local function add_bin(bin, parent_id)
        local display_name = bin.name
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
        local media = clip.media or (clip.media_id and M.media_map[clip.media_id]) or {}
        local assigned_bin = nil
        if M.media_bin_map then
            assigned_bin = M.media_bin_map[clip.clip_id]
        end
        clip.bin_id = assigned_bin
        if not clip.bin_id then
            local bin_tag = get_bin_tag(media)
            if bin_tag then
                local derived_bin_id = bin_path_lookup[bin_tag]
                clip.bin_id = derived_bin_id
            end
        end
        if clip.bin_id then
            local parent_tree = bin_tree_map[clip.bin_id]
            if parent_tree then
                add_master_clip_item(parent_tree, clip)
            else
                clip.bin_id = nil
                add_master_clip_item(nil, clip)
            end
        else
            add_master_clip_item(nil, clip)
        end
    end

    -- Master clips inside bins
    -- (handled above via assigned bin IDs)

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

    -- Create tab bar similar to timeline tabs
    local colors = ui_constants.COLORS or {}
    local tab_container = qt_constants.WIDGET.CREATE()
    local tab_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.LAYOUT.SET_ON_WIDGET(tab_container, tab_layout)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(tab_layout, 12, 6, 12, 0)
    qt_constants.CONTROL.SET_LAYOUT_SPACING(tab_layout, 6)
    qt_constants.PROPERTIES.SET_STYLE(tab_container, string.format(
        [[QWidget { background: %s; border-bottom: 1px solid %s; }]],
        colors.PANEL_BACKGROUND_COLOR or "#1f1f1f",
        colors.SCROLL_BORDER_COLOR or "#111111"
    ))

    local tab_label = qt_constants.WIDGET.CREATE_LABEL("Untitled Project")
    qt_constants.PROPERTIES.SET_STYLE(tab_label, string.format([[
        QLabel {
            background: transparent;
            color: %s;
            padding: 4px 10px;
            font-size: 11px;
            font-weight: bold;
            border: none;
            border-bottom: 2px solid %s;
        }
    ]], colors.WHITE_TEXT_COLOR or "#ffffff", colors.SELECTION_BORDER_COLOR or "#e64b3d"))
    qt_constants.LAYOUT.ADD_WIDGET(tab_layout, tab_label)
    qt_constants.LAYOUT.ADD_STRETCH(tab_layout, 1)
    qt_constants.LAYOUT.ADD_WIDGET(layout, tab_container)

    M.project_title_widget = tab_label
    if M.pending_project_title then
        local pending = M.pending_project_title
        M.pending_project_title = nil
        if qt_constants.PROPERTIES.SET_TEXT then
            qt_constants.PROPERTIES.SET_TEXT(tab_label, pending)
        end
    end
    -- Create tree widget for media library (Resolve style)
    local tree = qt_constants.WIDGET.CREATE_TREE()
    local disclosure_closed_icon = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 10 10'><path fill='%238c8c8c' d='M3 2l4 3-4 3z'/></svg>"
    local disclosure_open_icon = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 10 10'><path fill='%238c8c8c' d='M2 3l3 4 3-4z'/></svg>"

    local tree_style = string.format([[
        QTreeWidget {
            background: #262626;
            color: #cccccc;
            border: none;
            font-size: %s;
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
        QTreeView::branch {
            background: #262626;
            border: none;
            width: 12px;
        }
        QTreeView::branch:has-children {
            background: #262626;
            border: none;
        }
        QTreeView::branch:has-children:!has-siblings:closed,
        QTreeView::branch:closed:has-children {
            image: url("%s");
            width: 12px;
            height: 12px;
        }
        QTreeView::branch:has-children:!has-siblings:open,
        QTreeView::branch:open:has-children {
            image: url("%s");
            width: 12px;
            height: 12px;
        }
        QTreeView::branch:open:has-children:selected,
        QTreeView::branch:closed:has-children:selected {
            image: url("%s");
        }
        QTreeWidget::branch {
            background: #262626;
            border: none;
            width: 12px;
        }
        QTreeWidget::branch:has-children {
            background: #262626;
            border: none;
        }
        QTreeWidget::branch:has-children:!has-siblings:closed,
        QTreeWidget::branch:closed:has-children {
            image: url("%s");
            width: 12px;
            height: 12px;
        }
        QTreeWidget::branch:has-children:!has-siblings:open,
        QTreeWidget::branch:open:has-children {
            image: url("%s");
            width: 12px;
            height: 12px;
        }
        QTreeWidget::branch:open:has-children:selected,
        QTreeWidget::branch:closed:has-children:selected {
            image: url("%s");
        }
        QHeaderView::section {
            background: #2b2b2b;
            color: #888;
            padding: 4px;
            border: none;
            border-right: 1px solid #1a1a1a;
            font-size: %s;
            font-weight: normal;
        }
    ]], ui_constants.FONTS.DEFAULT_FONT_SIZE,
        disclosure_closed_icon, disclosure_open_icon, disclosure_open_icon,
        disclosure_closed_icon, disclosure_open_icon, disclosure_open_icon,
        ui_constants.FONTS.DEFAULT_FONT_SIZE)
    qt_constants.PROPERTIES.SET_STYLE(tree, tree_style)

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
    if qt_constants.CONTROL.SET_TREE_EXPANDS_ON_DOUBLE_CLICK then
        qt_constants.CONTROL.SET_TREE_EXPANDS_ON_DOUBLE_CLICK(tree, true)
    end

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
            if qt_set_focus then
                pcall(qt_set_focus, tree)
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

    if qt_constants.CONTROL.SET_CONTEXT_MENU_HANDLER then
        local context_handler = register_handler(function(evt)
            show_browser_context_menu(evt)
        end)
        qt_constants.CONTROL.SET_CONTEXT_MENU_HANDLER(tree, context_handler)
    end

    if qt_constants.CONTROL.SET_TREE_DRAG_DROP_MODE then
        qt_constants.CONTROL.SET_TREE_DRAG_DROP_MODE(tree, "internal")
    end
    if qt_constants.CONTROL.SET_TREE_DROP_HANDLER then
        local drop_handler = register_handler(function(evt)
            local ok, result = xpcall(function()
                return handle_tree_drop and handle_tree_drop(evt)
            end, debug.traceback)
            if not ok then
                print(string.format("ERROR: Project browser drop handler failed: %s", tostring(result)))
                return false
            end
            return result and true or false
        end)
        qt_constants.CONTROL.SET_TREE_DROP_HANDLER(tree, drop_handler)
    end
    if qt_constants.CONTROL.SET_TREE_KEY_HANDLER then
        local key_handler = register_handler(function(evt)
            local ok, handled = xpcall(function()
                return handle_tree_key_event(evt)
            end, debug.traceback)
            if not ok then
                print(string.format("ERROR: Project browser key handler failed: %s", tostring(handled)))
                return false
            end
            return handled and true or false
        end)
        qt_constants.CONTROL.SET_TREE_KEY_HANDLER(tree, key_handler)
    end

    qt_constants.LAYOUT.ADD_WIDGET(layout, tree)

    -- Set layout on container
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)

    -- Store references for later access
    M.tree = tree
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
end

function M.set_project_title(name)
    local label = M.project_title_widget
    local display = name and name ~= "" and name or "Untitled Project"
    if label and qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(label, display)
    else
        M.pending_project_title = display
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

function M.get_selection_snapshot()
    local snapshot = {}
    if not M.selected_items then
        return snapshot
    end
    for _, item in ipairs(M.selected_items) do
        local copy = {}
        for key, value in pairs(item) do
            copy[key] = value
        end
        snapshot[#snapshot + 1] = copy
    end
    return snapshot
end

-- Refresh media list from database
function M.refresh()
    ensure_command_listener()
    populate_tree()
end

local function handle_tree_drop(event)
    if not event or type(event.sources) ~= "table" or #event.sources == 0 then
        return false
    end

    local dragged_bins = {}
    local dragged_clips = {}

    for _, tree_id in ipairs(event.sources) do
        local info = lookup_item_by_tree_id(tree_id)
        if info and info.type == "bin" then
            table.insert(dragged_bins, info)
        elseif info and info.type == "master_clip" then
            table.insert(dragged_clips, info)
        else
            print("⚠️  Unsupported drag item")
            return true
        end
    end

    if #dragged_bins > 0 and #dragged_clips > 0 then
        print("⚠️  Mixed drag selections are not supported")
        return true
    end

    local target_info = lookup_item_by_tree_id(event.target_id)
    local position = (event.position or "viewport"):lower()

    local function resolve_bin_parent(target, pos)
        if pos == "viewport" then
            return nil
        end
        if target and target.type == "bin" then
            if pos == "into" then
                return target.id
            elseif pos == "above" or pos == "below" then
                return target.parent_id
            end
        elseif target and target.type == "master_clip" then
            return target.bin_id
        end
        return nil
    end

    if #dragged_bins > 0 then
        local new_parent_id = resolve_bin_parent(target_info, position)
        local changed = false
        for _, bin_info in ipairs(dragged_bins) do
            if bin_info.id ~= new_parent_id then
                if is_descendant(new_parent_id, bin_info.id) then
                    print("⚠️  Cannot move a bin inside one of its descendants")
                elseif set_bin_parent(bin_info.id, new_parent_id) then
                    changed = true
                end
            end
        end

        if not changed then
            return true
        end

        local project_id = M.project_id or db.get_current_project_id()
        local ok, err = tag_service.save_hierarchy(project_id, M.bins)
        if not ok then
            print(string.format("⚠️  Failed to save bin hierarchy after drag/drop: %s", tostring(err or "unknown error")))
            return true
        end

        local focus_bin = dragged_bins[1] and dragged_bins[1].id
        defer_to_ui(function()
            M.refresh()
            if focus_bin and M.focus_bin then
                M.focus_bin(focus_bin, {skip_activate = true})
            end
        end)
        return true
    end

    if #dragged_clips > 0 then
        local target_bin_id = resolve_bin_parent(target_info, position)
        local changed_ids = {}
        for _, clip_info in ipairs(dragged_clips) do
            if clip_info.bin_id ~= target_bin_id then
                clip_info.bin_id = target_bin_id
                if target_bin_id then
                    M.media_bin_map[clip_info.clip_id] = target_bin_id
                else
                    M.media_bin_map[clip_info.clip_id] = nil
                end
                table.insert(changed_ids, clip_info.clip_id)
            end
        end

        if #changed_ids == 0 then
            return true
        end

        local project_id = M.project_id or db.get_current_project_id()
        local ok, assign_err = tag_service.assign_master_clips(project_id, changed_ids, target_bin_id)
        if not ok then
            print(string.format("⚠️  Failed to persist media-bin assignments: %s", tostring(assign_err or "unknown error")))
            M.media_bin_map = tag_service.list_master_clip_assignments(project_id)
        end

        defer_to_ui(function()
            local first_clip = dragged_clips[1]
            local focus_item = nil
            M.refresh()
            if target_bin_id then
                M.focus_bin(target_bin_id, {skip_activate = true})
            elseif first_clip and first_clip.clip_id then
                local clip_entry = M.master_clip_map and M.master_clip_map[first_clip.clip_id]
                if clip_entry and clip_entry.tree_id and qt_constants.CONTROL.SET_TREE_CURRENT_ITEM then
                    qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(M.tree, clip_entry.tree_id, true, true)
                end
            end
        end)

        return true
    end

    return true
end

M._test_handle_tree_drop = handle_tree_drop

handle_tree_key_event = function(event)
    if not keymap or not keymap.handle then
        return false
    end

    return keymap.handle(event, {
        get_selected_item = function()
            return M.selected_item
        end,
        activate_sequence = function()
            local result = command_manager.execute(ACTIVATE_COMMAND)
            if not result or not result.success then
                print(string.format("⚠️  ActivateBrowserSelection failed: %s", result and result.error_message or "unknown error"))
                return false
            end
            return true
        end,
        focus_tree = focus_tree_widget,
        controls = qt_constants and qt_constants.CONTROL,
        tree_widget = function()
            return M.tree
        end,
        resolve_tree_id = function(item)
            if not item then
                return nil
            end
            if item.tree_id then
                return item.tree_id
            end
            if item.id and M.bin_map then
                local entry = M.bin_map[item.id]
                return entry and entry.tree_id or nil
            end
            return nil
        end,
    })
end

function M._test_get_tree_id(kind, id)
    if not kind or not id then
        return nil
    end
    if kind == "bin" then
        local bin = M.bin_map and M.bin_map[id]
        return bin and bin.tree_id or nil
    elseif kind == "master_clip" then
        local clip = M.master_clip_map and M.master_clip_map[id]
        return clip and clip.tree_id or nil
    elseif kind == "timeline" then
        local sequence = M.sequence_map and M.sequence_map[id]
        return sequence and sequence.tree_id or nil
    end
    return nil
end

local function start_inline_rename_after(focus_fn)
    defer_to_ui(function()
        if type(focus_fn) == "function" then
            focus_fn()
        end
        if M.start_inline_rename then
            M.start_inline_rename()
        end
    end)
end

local function create_bin_in_root()
    local project_id = current_project_id()
    local name_lookup = collect_name_lookup(M.bin_map)
    local temp_name = generate_sequential_label("Bin", name_lookup)

    local cmd = Command.create("NewBin", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("name", temp_name)

    local result = command_manager.execute(cmd)
    if not result or not result.success then
        print(string.format("⚠️  New Bin failed: %s", result and result.error_message or "unknown error"))
        return
    end

    local bin_definition = cmd:get_parameter("bin_definition")
    local new_bin_id = bin_definition and bin_definition.id
    if not new_bin_id then
        return
    end

    M.refresh()
    start_inline_rename_after(function()
        if M.focus_bin then
            M.focus_bin(new_bin_id, {skip_activate = true})
        end
    end)
end

local function create_sequence_in_project()
    local project_id = current_project_id()
    local name_lookup = collect_name_lookup(M.sequence_map)
    local temp_name = generate_sequential_label("Sequence", name_lookup)
    local defaults = sequence_defaults()

    local cmd = Command.create("CreateSequence", project_id)
    cmd:set_parameter("project_id", project_id)
    cmd:set_parameter("name", temp_name)
    cmd:set_parameter("frame_rate", defaults.frame_rate)
    cmd:set_parameter("width", defaults.width)
    cmd:set_parameter("height", defaults.height)

    local result = command_manager.execute(cmd)
    if not result or not result.success then
        print(string.format("⚠️  New Sequence failed: %s", result and result.error_message or "unknown error"))
        return
    end

    local sequence_id = cmd:get_parameter("sequence_id")
    if not sequence_id then
        return
    end

    M.refresh()
    start_inline_rename_after(function()
        if M.focus_sequence then
            M.focus_sequence(sequence_id, {skip_activate = true})
        end
    end)
end

local function show_browser_background_menu(global_x, global_y)
    if not M.tree then
        return
    end
    if not qt_constants.MENU or not qt_constants.MENU.CREATE_MENU or not qt_constants.MENU.SHOW_POPUP then
        print("⚠️  Context menu unavailable: Qt menu bindings missing")
        return
    end

    local actions = {
        {label = "New Bin", handler = create_bin_in_root},
        {label = "New Sequence", handler = create_sequence_in_project},
    }

    local menu = qt_constants.MENU.CREATE_MENU(M.tree, "ProjectBrowserBackground")
    for _, action_def in ipairs(actions) do
        local qt_action = qt_constants.MENU.CREATE_MENU_ACTION(menu, action_def.label)
        qt_constants.MENU.CONNECT_MENU_ACTION(qt_action, function()
            action_def.handler()
        end)
    end
    qt_constants.MENU.SHOW_POPUP(menu, math.floor(global_x or 0), math.floor(global_y or 0))
end

show_browser_context_menu = function(event)
    if not event or not M.tree then
        return
    end

    if not qt_constants.MENU or not qt_constants.MENU.CREATE_MENU or not qt_constants.MENU.SHOW_POPUP then
        print("⚠️  Context menu unavailable: Qt menu bindings missing")
        return
    end

    local local_x = math.floor(event.x or 0)
    local local_y = math.floor(event.y or 0)
    local global_x = event.global_x and math.floor(event.global_x) or nil
    local global_y = event.global_y and math.floor(event.global_y) or nil

    if (not global_x or not global_y) and qt_constants.WIDGET and qt_constants.WIDGET.MAP_TO_GLOBAL then
        global_x, global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(M.tree, local_x, local_y)
    end

    local clicked_tree_id = nil
    if qt_constants.CONTROL.GET_TREE_ITEM_AT then
        clicked_tree_id = qt_constants.CONTROL.GET_TREE_ITEM_AT(M.tree, local_x, local_y)
        if not clicked_tree_id then
            show_browser_background_menu(global_x, global_y)
            return
        end
    end

    if clicked_tree_id then
        local already_selected = false
        for _, selected in ipairs(M.selected_items or {}) do
            if selected.tree_id == clicked_tree_id then
                already_selected = true
                break
            end
        end

        if not already_selected then
            if qt_constants.CONTROL.SET_TREE_CURRENT_ITEM then
                qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(M.tree, clicked_tree_id, true, true)
            end
            local info = M.item_lookup and M.item_lookup[tostring(clicked_tree_id)]
            apply_single_selection(info)
        end
    end

    local selected_items = M.selected_items or {}
    if #selected_items == 0 and M.selected_item then
        selected_items = {M.selected_item}
    end
    if #selected_items == 0 then
        return
    end

    local selected_master = M.get_selected_master_clip()
    local primary_info = selected_items[1]
    local actions = {}

    if selected_master then
        table.insert(actions, {
            label = "Insert Into Timeline",
            handler = function()
                M.insert_selected_to_timeline()
            end
        })
        table.insert(actions, {
            label = "Reveal in Filesystem",
            handler = function()
                local result = command_manager.execute("RevealInFilesystem")
                if result and not result.success then
                    print(string.format("⚠️  Reveal in Filesystem failed: %s", result.error_message or "unknown error"))
                end
            end
        })
    end

    local rename_supported = primary_info and (primary_info.type == "master_clip"
        or primary_info.type == "timeline"
        or primary_info.type == "bin")
    if rename_supported and M.start_inline_rename then
        table.insert(actions, {
            label = "Rename...",
            handler = function()
                M.start_inline_rename()
            end
        })
    end

    table.insert(actions, {
        label = "Delete",
        handler = function()
            if not M.delete_selected_items() then
                print("⚠️  Delete failed: nothing selected")
            end
        end
    })

    if #actions == 0 then
        return
    end

    local menu = qt_constants.MENU.CREATE_MENU(M.tree, "ProjectBrowserContext")
    for _, action_def in ipairs(actions) do
        local qt_action = qt_constants.MENU.CREATE_MENU_ACTION(menu, action_def.label or "Action")
        if action_def.enabled == false then
            qt_constants.MENU.SET_ACTION_ENABLED(qt_action, false)
        else
            qt_constants.MENU.CONNECT_MENU_ACTION(qt_action, function()
                action_def.handler()
            end)
        end
    end

    qt_constants.MENU.SHOW_POPUP(menu, math.floor(global_x or 0), math.floor(global_y or 0))
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

    local insert_time = timeline_state_module.get_playhead_position and timeline_state_module.get_playhead_position() or 0
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

local function collect_all_tree_entries()
    local entries = {}
    if not M.item_lookup then
        return entries
    end
    for tree_id_str, info in pairs(M.item_lookup) do
        if type(info) == "table" then
            local numeric_id = tonumber(tree_id_str)
            table.insert(entries, {tree_id = numeric_id, info = info})
        end
    end
    table.sort(entries, function(a, b)
        return (a.tree_id or math.huge) < (b.tree_id or math.huge)
    end)
    return entries
end

function M.select_all_items()
    if not M.tree or not M.item_lookup then
        return false, "Project browser not initialized"
    end

    local entries = collect_all_tree_entries()
    if #entries == 0 then
        browser_state.clear_selection()
        M.selected_items = {}
        M.selected_item = nil
        return false, "No items available to select"
    end

    if qt_constants.CONTROL.SET_TREE_CURRENT_ITEM then
        is_restoring_selection = true
        for index, entry in ipairs(entries) do
            qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(M.tree, entry.tree_id, true, index == 1)
        end
        is_restoring_selection = false
    end

    local collected = {}
    for _, entry in ipairs(entries) do
        table.insert(collected, entry.info)
    end
    M.selected_items = collected
    M.selected_item = collected[1]
    browser_state.update_selection(collected, selection_context())
    return true
end

function M.delete_selected_items()
    if not M.selected_items or #M.selected_items == 0 then
        return false
    end

    local Command = require("command")
    local deleted = 0
    local clip_failures = 0
    local sequence_failures = 0
    local bin_failures = 0

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
        elseif item.type == "bin" and item.id then
            local project_id = M.project_id or "default_project"
            local cmd = Command.create("DeleteBin", project_id)
            cmd:set_parameter("project_id", project_id)
            cmd:set_parameter("bin_id", item.id)
            local result = command_manager.execute(cmd)
            if result and result.success then
                deleted = deleted + 1
            else
                bin_failures = bin_failures + 1
                print(string.format("⚠️  Delete bin %s failed: %s", tostring(item.name or item.id), result and result.error_message or "unknown error"))
            end
        end
    end

    if deleted > 0 then
        M.refresh()
        return true
    end

    if clip_failures > 0 or sequence_failures > 0 or bin_failures > 0 then
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
    browser_state.update_selection({info}, selection_context())
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
    local skip_expand = opts.skip_expand == true or opts.preserve_expansion == true
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

    if not skip_expand then
        expand_bin_chain(bin_id)
    end

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
        if qt_set_focus then
            pcall(qt_set_focus, M.tree)
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
    if qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE and tree_id then
        editable_ok = qt_constants.CONTROL.SET_TREE_ITEM_EDITABLE(M.tree, tree_id, true)
        print(string.format("Rename: SET_TREE_ITEM_EDITABLE result=%s", tostring(editable_ok)))
    else
        print("Rename: SET_TREE_ITEM_EDITABLE missing")
    end

    local edit_started = false
    if qt_constants.CONTROL.EDIT_TREE_ITEM and tree_id then
        edit_started = qt_constants.CONTROL.EDIT_TREE_ITEM(M.tree, tree_id, 0)
        print(string.format("Rename: EDIT_TREE_ITEM result=%s", tostring(edit_started)))
    else
        print("Rename: EDIT_TREE_ITEM missing")
    end
    return edit_started
end

function M.focus_sequence(sequence_id, opts)
    opts = opts or {}
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

    if not opts.skip_focus then
        if focus_manager and focus_manager.focus_panel then
            focus_manager.focus_panel("project_browser")
        else
            focus_manager.set_focused_panel("project_browser")
        end
        if qt_set_focus then
            pcall(qt_set_focus, M.tree)
        end
    end

    if not opts.skip_activate then
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
