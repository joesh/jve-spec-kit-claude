--- Project Browser - Media library and bin management
-- Shows imported media files, allows drag-to-timeline
-- Mimics DaVinci Resolve Media Pool style
-- luacheck: globals qt_set_focus qt_line_edit_select_all qt_set_line_edit_text_changed_handler qt_set_line_edit_return_pressed_handler
local View = require("ui.view")
local M = View.new("project_browser")
local db = require("core.database")
local tag_service = require("core.tag_service")
local ui_constants = require("core.ui_constants")
local focus_manager = require("ui.focus_manager")
local command_manager = require("core.command_manager")
local command_scope = require("core.command_scope")
local Command = require("command")
local json = require("dkjson")
local browser_state = require("ui.project_browser.browser_state")
local frame_utils = require("core.frame_utils")
local keymap = require("ui.project_browser.keymap")
local qt_constants = require("core.qt_constants")
local profile_scope = require("core.profile_scope")
local log = require("core.logger").for_area("ui")
local uuid = require("uuid")
local project_gen = require("core.project_generation")
local path_utils = require("core.path_utils")
local browser_sort = require("ui.browser_sort")
local media_status = require("core.media.media_status")

local handler_seq = 0

-- Icon file paths resolved from repo root
local icon_dir = path_utils.resolve_repo_root() .. "/resources/icons"
local ICONS = {
    bin                 = icon_dir .. "/bin.svg",
    timeline            = icon_dir .. "/timeline.svg",
    clip_video          = icon_dir .. "/clip_video.svg",
    clip_audio          = icon_dir .. "/clip_audio.svg",
    clip_still          = icon_dir .. "/clip_still.svg",
    clip_video_offline  = icon_dir .. "/clip_video_offline.svg",
    clip_audio_offline  = icon_dir .. "/clip_audio_offline.svg",
    clip_still_offline  = icon_dir .. "/clip_still_offline.svg",
}

-- Classify a master-clip row into a media-kind icon bucket.
-- Priority: still > video > audio. Compound masterclip-sequences (no media row,
-- no width/audio_channels) resolve to "video" — they read as clips to the user
-- and video is the common case (deliberate domain choice, not a fallback).
local function classify_clip_media_kind(clip, media)
    assert(clip, "classify_clip_media_kind: clip required")
    media = media or {}
    if clip.is_still or media.is_still then return "still" end
    local width = clip.width or media.width
    if width and width > 0 then return "video" end
    local audio_channels = media.audio_channels or clip.audio_channels
    if audio_channels and audio_channels > 0 then return "audio" end
    return "video"  -- compound masterclip / unknown → video (domain choice)
end

-- Map (media_kind, offline?) → ICONS key path.
local function pick_clip_icon(media_kind, offline)
    assert(media_kind, "pick_clip_icon: media_kind required")
    local suffix = offline and "_offline" or ""
    local key = "clip_" .. media_kind .. suffix
    return assert(ICONS[key], "pick_clip_icon: unknown icon key: " .. key)
end

-- Column indices (0-based)
local COL_NAME       = 0
local COL_DURATION   = 1
local COL_RESOLUTION = 2
local COL_FPS        = 3
local COL_CODEC      = 4
local COL_DATE       = 5

-- Base header labels (no sort indicators)
local BASE_HEADERS = {"Clip Name", "Duration", "Resolution", "FPS", "Codec", "Date Modified"}

-- Sort state (module-level, loaded from project settings on first populate)
local sort_state = {
    primary_col = COL_NAME,
    primary_order = "asc",
    secondary_col = nil,
    secondary_order = nil,
    loaded = false,
}

local function selection_context()
    -- nil _project_gen = browser is between projects (on_project_change cleared
    -- state but populate_tree hasn't run yet). Selection events during this
    -- window are Qt noise from tree clearing — return nil to signal "no valid context."
    if not M._project_gen then
        return nil
    end
    project_gen.check(M._project_gen, "project_browser.selection_context")
    return {
        master_lookup = M.master_clip_map,
        media_lookup = M.media_map,
        sequence_lookup = M.sequence_map,
        project_id = M.project_id,
        bin_lookup = M.media_bin_map
    }
end

-- Route browser selection through SelectBrowserItems command
local function select_browser_items(items, context, modifiers)
    context = context or selection_context()
    if not context then return end  -- browser between projects, ignore

    command_manager.execute_interactive("SelectBrowserItems", {
        project_id = M.project_id or context.project_id or "unknown",
        items = items or {},
        context = context,
        modifiers = modifiers or {},
    })
end

local function clear_browser_selection()
    select_browser_items({}, selection_context())
end

local REFRESH_COMMANDS = {
    ImportMedia = true,
    ImportFCP7XML = true,
    DeleteMasterClip = true,
    DeleteSequence = true,
    DuplicateMasterClip = true,
    RenameItem = true,
    ImportResolveProject = true,
    ImportResolveTimeline = true,
    ImportResolveDatabase = true,
    ImportPremiereProject = true,
    CreateSequence = true,
}

local command_listener_registered = false
local is_restoring_selection = false
local show_browser_context_menu  -- forward declaration for tree context menu handler
local handle_tree_key_event      -- forward declaration for key handler
local handle_tree_drop           -- forward declaration for drop handler

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


--- Defer callback to next event loop cycle. Only for Qt widget interaction
--- timing (e.g. tree selection must be processed before entering edit mode).
--- NEVER use for model/data flow — that's a timing hack.
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
    local value = M.project_id or db.get_current_project_id()
    assert(value and value ~= "", "project_browser.current_project_id: no project_id available")
    return value
end

local function sequence_defaults()
    local timeline_panel = M.timeline_panel
    local timeline_state_module = timeline_panel and timeline_panel.get_state and timeline_panel.get_state()
    local sequence_id = timeline_state_module and timeline_state_module.get_tab_strip():active_sequence_id()
    assert(sequence_id and sequence_id ~= "", "project_browser.sequence_defaults: no active sequence_id to derive defaults from")
    local record = db.load_sequence_record(sequence_id)
    assert(record, string.format("project_browser.sequence_defaults: failed to load sequence record for %s", sequence_id))
    assert(record.frame_rate, string.format("project_browser.sequence_defaults: sequence %s missing frame_rate", sequence_id))
    assert(record.width, string.format("project_browser.sequence_defaults: sequence %s missing width", sequence_id))
    assert(record.height, string.format("project_browser.sequence_defaults: sequence %s missing height", sequence_id))
    assert(record.audio_sample_rate, string.format("project_browser.sequence_defaults: sequence %s missing audio_sample_rate", sequence_id))
    return {
        frame_rate        = record.frame_rate,
        width             = record.width,
        height            = record.height,
        audio_sample_rate = record.audio_sample_rate,
    }
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
    local result = command_manager.execute_interactive("RenameItem", {
        ["project_id"] = project_id,
                ["target_type"] = pending.target_type,
                ["target_id"] = pending.target_id,
                ["new_name"] = trimmed_name,
                ["previous_name"] = pending.original_name,
    })
    if result and result.success then
        log.event("RenameItem executed for %s → %s", tostring(pending.target_id), trimmed_name)
    else
        log.warn("RenameItem failed for %s → %s (%s)", tostring(pending.target_id), trimmed_name, result and result.error_message or "unknown error")
        if qt_constants.CONTROL.SET_TREE_ITEM_TEXT then
            qt_constants.CONTROL.SET_TREE_ITEM_TEXT(M.tree, pending.tree_id, pending.original_name or "", 0)
        end
        M.pending_rename = nil
        return
    end

    -- MVC: no manual cache patching — command_listener already triggers
    -- M.refresh() which rebuilds from DB. Timeline reload is handled by
    -- command_helper.reload_timeline() inside RenameItem executor +
    -- content_changed signal from command_manager.

    if pending.target_type ~= "bin" then
        select_browser_items(M.selected_items or {})
    end

    pending.preview_name = nil
    M.pending_rename = nil
    -- MVC: command_listener triggers M.refresh() which re-runs active find
end

M._test_finalize_pending_rename = finalize_pending_rename

local function handle_tree_editor_closed(event)
    if not M.pending_rename then
        return
    end

    log.event("Rename close event: item=%s accepted=%s text=%s",
        tostring(event and event.item_id), tostring(event and event.accepted), tostring(event and event.text))

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

    log.event("Rename change event: item=%s column=%s text=%s pending_tree=%s",
        tostring(event.item_id), tostring(event.column), tostring(event.text), tostring(pending.tree_id))
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
M.project_title_widget = nil
M.pending_project_title = nil

local ACTIVATE_COMMAND = "ActivateBrowserSelection"

-- 019 FR-020/021/022: route activation through the command_manager via
-- the OpenSequenceIn{Source,Timeline} commands. Bins keep their direct
-- focus_bin path (no model mutation, no destination ambiguity, not a
-- "source" the way clips/sequences are).
--
-- Modifier override (FR-022): Opt held on a clip-sequence ("timeline")
-- entry routes to the source viewer instead of the timeline panel.
-- Caller supplies modifiers (or nil for the default no-modifier route).
local function activate_item(item_info, modifiers)
    if not item_info or type(item_info) ~= "table" then
        return false, "No browser item selected"
    end
    modifiers = modifiers or {}

    if item_info.type == "timeline" then
        local project_id = item_info.project_id or M.project_id
        if modifiers.alt then
            command_manager.execute_interactive("OpenSequenceInSourceMonitor", {
                sequence_id = item_info.id,
                project_id  = project_id,
            })
        else
            command_manager.execute_interactive("OpenSequenceInTimeline", {
                sequence_id = item_info.id,
                project_id  = project_id,
            })
        end
        return true
    elseif item_info.type == "master_clip" then
        local clip = item_info.clip_id and M.master_clip_map[item_info.clip_id]
            or (item_info.media_id and M.master_clip_map[item_info.media_id])
        if not clip then
            return false, "Master clip metadata missing"
        end
        command_manager.execute_interactive("OpenSequenceInSourceMonitor", {
            sequence_id = clip.clip_id,
            project_id  = item_info.project_id or M.project_id,
        })
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

local function format_duration(duration_input, frame_rate)
    if not duration_input then
        return "--:--"
    end
    -- Both inputs must be valid; no pcall-swallow, no ms-fallback path.
    -- Callers populate frame_rate from authoritative model fields
    -- (clip.rate / sequence.frame_rate); a missing or malformed rate is
    -- a producer bug and should fail loud here, not paper over with a
    -- minutes:seconds approximation that hides the broken upstream.
    assert(frame_rate, "project_browser.format_duration: frame_rate must not be nil")
    return frame_utils.format_timecode(duration_input, frame_rate)
end

local function format_date(timestamp)
    if not timestamp or timestamp == 0 then
        return ""
    end
    return os.date("%b %d %Y", timestamp)
end

local function get_fps_float(rate)
    if type(rate) == "table" and rate.fps_numerator then
        if rate.fps_denominator == 0 then return 0 end
        return rate.fps_numerator / rate.fps_denominator
    elseif type(rate) == "number" then
        return rate
    end
    return 0
end

local function resolve_tree_item(entry)
    if not entry then
        return nil
    end

    if type(entry) == "number" or type(entry) == "string" then
        if M.item_lookup then
            return M.item_lookup[tostring(entry)]
        end
        return nil
    end

    if type(entry) ~= "table" then
        log.warn("resolve_tree_item received non-table entry: %s", tostring(type(entry)))
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
    select_browser_items(collected)
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
    assert(project_id and project_id ~= "", "project_browser.populate_tree: no project_id available")
    M.project_id = project_id
    M._project_gen = project_gen.current()

    local settings = db.get_project_settings(M.project_id)

    -- Load sort + expanded state from project settings (first populate only)
    if not sort_state.loaded then
        sort_state.primary_col = settings.browser_sort_primary_column or COL_NAME
        sort_state.primary_order = settings.browser_sort_primary_order or "asc"
        sort_state.secondary_col = settings.browser_sort_secondary_column
        sort_state.secondary_order = settings.browser_sort_secondary_order
        sort_state.loaded = true
    end
    local saved_expanded_bins = settings.browser_expanded_bins

    M.media_bin_map = tag_service.list_master_clip_assignments(M.project_id)
    local seq_bin_map = tag_service.list_sequence_assignments(M.project_id)

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
        qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, tree_id, ICONS.bin)
        bin_tree_map[bin.id] = tree_id
        if M.bin_map[bin.id] then
            M.bin_map[bin.id].tree_id = tree_id
        end
        return tree_id
    end

    local function add_sequence_item(parent_tree_id, sequence)
        local duration_str = format_duration(sequence.duration, sequence.frame_rate)
        local resolution_str = (sequence.width and sequence.height and sequence.width > 0)
            and string.format("%dx%d", sequence.width, sequence.height)
            or ""
        local fps_val = get_fps_float(sequence.frame_rate)
        local fps_str = (fps_val > 0) and string.format("%.2f", fps_val) or ""

        local columns = { sequence.name, duration_str, resolution_str, fps_str, "Timeline", "" }
        local tree_id
        if parent_tree_id then
            tree_id = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(M.tree, parent_tree_id, columns)
        else
            tree_id = qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, columns)
        end

        local sequence_info = {
            type = "timeline",
            id = sequence.id,
            project_id = sequence.project_id or project_id,
            name = sequence.name,
            frame_rate = sequence.frame_rate,
            width = sequence.width,
            height = sequence.height,
            duration = sequence.duration,
            tree_id = tree_id
        }
        store_tree_item(M.tree, tree_id, sequence_info)
        M.sequence_map[sequence.id] = sequence_info
        qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, tree_id, ICONS.timeline)
    end

    -- Collect timeline sequences for bin-aware placement. db.load_sequences
    -- already filters WHERE kind='sequence' at the SQL layer (only valid
    -- non-master kind per schema CHECK constraint), so no second client-side
    -- filter is needed — and the previous one looked for kind=='timeline',
    -- a stale name that rejected every actual row.
    local timeline_sequences = {}
    for _, sequence in ipairs(sequences) do
        -- db.load_sequences does not populate `.type`; this loop stamps it.
        -- "timeline" is the browser-display type tag for kind='sequence' rows
        -- (master clips use type='master_clip' via a separate path). No
        -- `or` fallback — load_sequences is the only source of these rows
        -- and an upstream that pre-set `.type` would be a contract breach.
        assert(sequence.type == nil, string.format(
            "project_browser: load_sequences row %s arrived with type=%q already set",
            tostring(sequence.id), tostring(sequence.type)))
        sequence.type = "timeline"
        sequence.fps_float = get_fps_float(sequence.frame_rate)
        sequence.codec = "Timeline"
        table.insert(timeline_sequences, sequence)
    end

    -- Enrich master clips with sort-friendly fields
    for _, clip in ipairs(master_clips) do
        local media = clip.media or (clip.media_id and M.media_map[clip.media_id]) or {}
        clip.type = clip.type or "master_clip"
        clip.name = clip.name or media.name or clip.clip_id
        -- V13: master clip rate comes from the master sequence row
        -- (sequences.fps_numerator NOT NULL by schema). No fallback to
        -- media.frame_rate — that stub is nil-fielded for orphaned
        -- masters (Media:delete leaves shells, models/media.lua:1271).
        assert(clip.frame_rate, string.format(
            "project_browser: master clip %s missing rate", tostring(clip.clip_id)))
        clip.fps_float = get_fps_float(clip.frame_rate)
        clip.codec = clip.codec or media.codec or ""  -- lint-allow: R010 codec backfill chain; nullable for partially-probed media
        clip.width = clip.width or media.width
        clip.height = clip.height or media.height
        clip.duration = clip.duration or media.duration
        clip.modified_at = clip.modified_at or clip.created_at or media.modified_at or media.created_at
    end

    -- Bins must be added in depth order (parents before children).
    -- Final sort is done by Qt's SORT_TREE after all items are added.

    -- Root sequences (those NOT assigned to a bin)
    for _, sequence in ipairs(timeline_sequences) do
        if not seq_bin_map[sequence.id] then
            add_sequence_item(nil, sequence)
        end
    end

    -- Sort bins parent-before-child (by depth), then add to tree
    local function bin_depth(bin)
        local d = 0
        local cur = bin
        while cur and cur.parent_id do
            d = d + 1
            cur = bin_lookup[cur.parent_id]
        end
        return d
    end
    table.sort(bins, function(a, b)
        local da, db = bin_depth(a), bin_depth(b)
        if da ~= db then return da < db end
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)
    for _, bin in ipairs(bins) do
        local parent_tree = bin.parent_id and bin_tree_map[bin.parent_id] or nil
        add_bin(bin, parent_tree)
    end

    -- Smart Bins (FR-062): add after regular bins with distinct label
    local smart_bins_list = db.load_smart_bins(project_id)
    for _, sb in ipairs(smart_bins_list) do
        local display_name = "🔍 " .. sb.name
        local tree_id = qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, {display_name, "", "", "", "", ""})
        store_tree_item(M.tree, tree_id, {
            type = "smart_bin",
            id = sb.id,
            name = sb.name,
            criteria_json = sb.criteria_json,
            scope_bin_id = sb.scope_bin_id,
        })
        qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, tree_id, ICONS.bin)
    end

    -- Sequences inside bins
    for _, sequence in ipairs(timeline_sequences) do
        local bin_ids = seq_bin_map[sequence.id]
        if bin_ids then
            for _, bid in ipairs(bin_ids) do
                if bin_tree_map[bid] then
                    add_sequence_item(bin_tree_map[bid], sequence)
                end
            end
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
        -- Pull offline state from authoritative cache (same as timeline renderer).
        media_status.ensure_clip_status(clip)
        local duration_ms = clip.duration or media.duration
        -- V13: clip.frame_rate is the master sequence's fps, NOT NULL by schema.
        -- No fallback to media.frame_rate — orphan masters (post-
        -- Media:delete, models/media.lua:1271) carry a stub media table
        -- with nil-fielded frame_rate that would crash format_timecode.
        assert(clip.frame_rate, string.format(
            "project_browser.add_master_clip_item: clip %s missing rate",
            tostring(clip.clip_id)))
        local duration_str = format_duration(duration_ms, clip.frame_rate)
        local display_width = clip.width or media.width
        local display_height = clip.height or media.height
        local display_fps = clip.frame_rate
        local resolution_str = (display_width and display_height and display_width > 0)
            and string.format("%dx%d", display_width, display_height)
            or ""
        
        local fps_val = get_fps_float(display_fps)
        local fps_str = (fps_val > 0)
            and string.format("%.2f", fps_val)
            or ""
        
        local codec_str = clip.codec or media.codec or ""  -- lint-allow: R010 codec display, nullable for partially-probed media
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

        local media_kind = classify_clip_media_kind(clip, media)
        store_tree_item(M.tree, tree_id, {
            type = "master_clip",
            clip_id = clip.clip_id,
            media_id = clip.media_id,
            sequence_id = clip.sequence_id or clip.clip_id,
            bin_id = clip.bin_id,
            name = clip.name or media.name or clip.clip_id,
            file_path = clip.file_path or media.file_path,
            duration = duration_ms,
            frame_rate = display_fps,
            width = display_width,
            height = display_height,
            codec = codec_str,
            metadata = media.metadata,
            offline = clip.offline,
            media_kind = media_kind,
        })
        -- Icon updated reactively via media_status_changed signal (lazy eval)
        qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, tree_id, pick_clip_icon(media_kind, clip.offline))
        clip.tree_id = tree_id
    end

    -- Sift filtering removed — will return as proper browser-only filter UI

    -- Master clips: show in each assigned bin (many-to-many)
    for _, clip in ipairs(master_clips) do
        local bin_ids = M.media_bin_map and M.media_bin_map[clip.clip_id] or {}
        local placed = false
        for _, bid in ipairs(bin_ids) do
            local parent_tree = bin_tree_map[bid]
            if parent_tree then
                clip.bin_id = bid
                add_master_clip_item(parent_tree, clip)
                placed = true
            end
        end
        if not placed then
            clip.bin_id = nil
            add_master_clip_item(nil, clip)
        end
    end

    -- Sort the tree in-place by current sort column.
    -- Qt handles sorting within each level (root items + within each bin).
    qt_constants.CONTROL.SORT_TREE(M.tree, sort_state.primary_col,
        sort_state.primary_order or "asc")

    local function restore_previous_selection_from_cache(previous)
        if not previous or #previous == 0 then
            clear_browser_selection()
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
            clear_browser_selection()
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
                select_browser_items(collected)
            end
        else
            local collected = {}
            for _, match in ipairs(matches) do
                table.insert(collected, match.info)
            end
            M.selected_items = collected
            M.selected_item = collected[1]
            select_browser_items(collected)
        end
    end

    restore_previous_selection_from_cache(previous_selection)

    -- Restore expanded bins from saved state
    if saved_expanded_bins and type(saved_expanded_bins) == "table" then
        for _, bin_id in ipairs(saved_expanded_bins) do
            local tree_id = bin_tree_map[bin_id]
            if tree_id then
                qt_constants.CONTROL.SET_TREE_ITEM_EXPANDED(M.tree, tree_id, true)
            end
        end
    end

    -- Update header labels with sort indicators
    local labels = browser_sort.build_header_labels(BASE_HEADERS, sort_state)
    qt_constants.CONTROL.SET_TREE_HEADERS(M.tree, labels)

    M.bin_tree_map = bin_tree_map
end

local function save_sort_state()
    if not M.project_id then return end
    db.set_project_setting(M.project_id, "browser_sort_primary_column", sort_state.primary_col)
    db.set_project_setting(M.project_id, "browser_sort_primary_order", sort_state.primary_order)
    db.set_project_setting(M.project_id, "browser_sort_secondary_column", sort_state.secondary_col)
    db.set_project_setting(M.project_id, "browser_sort_secondary_order", sort_state.secondary_order)
end

local function save_expanded_bins()
    if not M.project_id or not M.tree or not M.bin_tree_map then return end
    local expanded = {}
    for bin_id, tree_id in pairs(M.bin_tree_map) do
        if qt_constants.CONTROL.IS_TREE_ITEM_EXPANDED(M.tree, tree_id) then
            table.insert(expanded, bin_id)
        end
    end
    db.set_project_setting(M.project_id, "browser_expanded_bins", expanded)
end

local function apply_column_widths()
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(M.tree, 0, 180)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(M.tree, 1, 80)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(M.tree, 2, 80)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(M.tree, 3, 50)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(M.tree, 4, 60)
    qt_constants.CONTROL.SET_TREE_COLUMN_WIDTH(M.tree, 5, 100)
end

-- Create project browser widget
function M.create()
    -- Create container
    -- luacheck: globals qt_create_focus_container qt_set_container_default_button
    local container = qt_create_focus_container()  -- Tab wraps within panel via focusNextPrevChild
    -- Opaque background prevents resize artifacts (transparent children leave ghost pixels)
    -- No blanket QWidget stylesheet — Fusion dark palette handles colors.
    -- Blanket QWidget rules override palette for all children (breaks combobox highlight etc.)
    local layout = qt_constants.LAYOUT.CREATE_VBOX()

    -- Set layout spacing
    qt_constants.CONTROL.SET_LAYOUT_SPACING(layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(layout, 0, 0, 0, 0)

    -- Create tab bar similar to timeline tabs. All UI chrome colors are
    -- required (rule 2.13: no fallbacks); ui_constants supplies every key.
    local colors = assert(ui_constants.COLORS,
        "project_browser: ui_constants.COLORS missing — required for UI chrome")
    local function color(key)
        return assert(colors[key],
            "project_browser: ui_constants.COLORS." .. key .. " is required")
    end
    local tab_container = qt_constants.WIDGET.CREATE()
    local tab_layout = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.LAYOUT.SET_ON_WIDGET(tab_container, tab_layout)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(tab_layout, 12, 6, 12, 0)
    qt_constants.CONTROL.SET_LAYOUT_SPACING(tab_layout, 6)
    qt_constants.PROPERTIES.SET_STYLE(tab_container, string.format(
        [[QWidget { background: %s; border-bottom: 1px solid %s; }]],
        color("PANEL_BACKGROUND_COLOR"),
        color("SCROLL_BORDER_COLOR")
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
    ]], color("WHITE_TEXT_COLOR"), color("SELECTION_BORDER_COLOR")))
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

    -- CSS: item colors, header — no branch rules (native Qt disclosure triangles)
    -- Minimal tree styling — let Fusion dark palette handle selection, focus, hover.
    -- Only set font size and header appearance.
    local tree_style = string.format([[
        QTreeWidget {
            font-size: %s;
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
        ui_constants.FONTS.DEFAULT_FONT_SIZE)
    qt_constants.PROPERTIES.SET_STYLE(tree, tree_style)

    -- Tree columns: Name, Duration, Resolution, FPS, Codec, Date Modified.
    qt_constants.CONTROL.SET_TREE_HEADERS(tree, BASE_HEADERS)
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
        qt_constants.CONTROL.SET_TREE_SELECTION_MODE(tree, "ExtendedSelection")
    end

    M.tree = tree
    M.project_id = db.get_current_project_id()
    ensure_command_listener()
    populate_tree()

    -- Header click → sort in-place (no rebuild)
    local header_click_handler = register_handler(function(col, cmd_held)
        browser_sort.handle_header_click(sort_state, col, cmd_held)
        save_sort_state()
        qt_constants.CONTROL.SORT_TREE(tree, sort_state.primary_col,
            sort_state.primary_order or "asc")
        -- Update header labels to show sort indicators
        local labels = browser_sort.build_header_labels(BASE_HEADERS, sort_state)
        qt_constants.CONTROL.SET_TREE_HEADERS(tree, labels)
        apply_column_widths()
    end)
    qt_constants.CONTROL.SET_TREE_HEADER_CLICK_HANDLER(tree, header_click_handler)

    -- Expand/collapse → persist
    local expand_collapse_handler = register_handler(function(_event)
        save_expanded_bins()
    end)
    qt_constants.CONTROL.SET_TREE_EXPAND_COLLAPSE_HANDLER(tree, expand_collapse_handler)

    local selection_handler = register_handler(function(event)
        local collected = {}

        if type(event) == "table" and type(event.items) == "table" then
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

        select_browser_items(collected)

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
        if not item_info and type(event) == "table" and type(event.items) == "table" then
            item_info = resolve_tree_item(event.items[1])
        end

        if not item_info or type(item_info) ~= "table" then
            return
        end

        M.selected_item = item_info
        local result
        result = command_manager.execute_interactive(ACTIVATE_COMMAND)
        if not result.success then
            log.warn("ActivateBrowserSelection failed: %s", tostring(result.error_message or "unknown error"))
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
                log.error("Drop handler failed: %s", tostring(result))
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
                log.error("Key handler failed: %s", tostring(handled))
                return false
            end
            return handled and true or false
        end)
        qt_constants.CONTROL.SET_TREE_KEY_HANDLER(tree, key_handler)
    end

    -- ========================================================================
    -- Find bar (Avid-style, hidden by default, Cmd+F toggles)
    -- ========================================================================
    local find_bar_container = qt_constants.WIDGET.CREATE()
    local find_bar_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(find_bar_layout, 2)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(find_bar_layout, 4, 2, 4, 2)

    -- Row 1: Find: [____×] [←] [→] 3/16  [Any ▼]
    local find_row = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.LAYOUT.ADD_WIDGET(find_row, qt_constants.WIDGET.CREATE_LABEL("Find:"))
    local find_edit = qt_constants.WIDGET.CREATE_LINE_EDIT("")
    qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT(find_edit, "search")
    if qt_constants.GEOMETRY and qt_constants.GEOMETRY.SET_SIZE_POLICY then
        qt_constants.GEOMETRY.SET_SIZE_POLICY(find_edit, "Expanding", "Fixed")
    end
    qt_constants.LAYOUT.ADD_WIDGET(find_row, find_edit)

    -- Let Fusion palette handle focus/hover/pressed on regular buttons.
    -- Only the default button (Next) gets accent styling.
    local prev_btn = qt_constants.WIDGET.CREATE_BUTTON("\xE2\x86\x90")  -- ←
    local next_btn = qt_constants.WIDGET.CREATE_BUTTON("\xE2\x86\x92")  -- →
    qt_constants.PROPERTIES.SET_STYLE(next_btn,
        "QPushButton { background-color: #0a84ff; color: white; "
        .. "min-width: 20px; max-width: 20px; padding: 1px 2px; border-radius: 3px; }")
    qt_constants.LAYOUT.ADD_WIDGET(find_row, prev_btn)
    qt_constants.LAYOUT.ADD_WIDGET(find_row, next_btn)

    local match_label = qt_constants.WIDGET.CREATE_LABEL("")
    qt_constants.PROPERTIES.SET_STYLE(match_label, "QLabel { min-width: 45px; }")
    qt_constants.LAYOUT.ADD_WIDGET(find_row, match_label)

    local attr_combo = qt_constants.WIDGET.CREATE_COMBOBOX()
    local query_engine = require("core.query_engine")
    qt_constants.PROPERTIES.ADD_COMBOBOX_ITEM(attr_combo, "Any")
    for _, f in ipairs(query_engine.get_searchable_fields()) do
        qt_constants.PROPERTIES.ADD_COMBOBOX_ITEM(attr_combo, f.name)
    end
    qt_constants.LAYOUT.ADD_WIDGET(find_row, attr_combo)

    local all_btn = qt_constants.WIDGET.CREATE_BUTTON("All")
    -- No per-widget stylesheet — Fusion palette handles focus/hover/pressed
    qt_constants.LAYOUT.ADD_WIDGET(find_row, all_btn)

    qt_constants.LAYOUT.ADD_LAYOUT(find_bar_layout, find_row)

    -- Row 2: Replace (hidden by default, shown when replace_edit has text)
    local replace_container = qt_constants.WIDGET.CREATE()
    local replace_row = qt_constants.LAYOUT.CREATE_HBOX()
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(replace_row, 0, 0, 0, 0)
    qt_constants.LAYOUT.ADD_WIDGET(replace_row, qt_constants.WIDGET.CREATE_LABEL("Replace:"))
    local replace_edit = qt_constants.WIDGET.CREATE_LINE_EDIT("")
    qt_constants.PROPERTIES.SET_PLACEHOLDER_TEXT(replace_edit, "replacement")
    if qt_constants.GEOMETRY and qt_constants.GEOMETRY.SET_SIZE_POLICY then
        qt_constants.GEOMETRY.SET_SIZE_POLICY(replace_edit, "Expanding", "Fixed")
    end
    qt_constants.LAYOUT.ADD_WIDGET(replace_row, replace_edit)

    local rep_btn = qt_constants.WIDGET.CREATE_BUTTON("Replace")
    qt_constants.CONTROL.SET_ENABLED(rep_btn, false)
    qt_constants.LAYOUT.ADD_WIDGET(replace_row, rep_btn)

    local rep_find_btn = qt_constants.WIDGET.CREATE_BUTTON("Replace & Find")
    qt_constants.CONTROL.SET_ENABLED(rep_find_btn, false)
    qt_constants.LAYOUT.ADD_WIDGET(replace_row, rep_find_btn)

    local rep_all_btn = qt_constants.WIDGET.CREATE_BUTTON("Replace All")
    qt_constants.CONTROL.SET_ENABLED(rep_all_btn, false)
    qt_constants.LAYOUT.ADD_WIDGET(replace_row, rep_all_btn)

    qt_constants.LAYOUT.SET_ON_WIDGET(replace_container, replace_row)
    -- Hidden by default
    if qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
        qt_constants.DISPLAY.SET_VISIBLE(replace_container, false)
    end
    qt_constants.LAYOUT.ADD_WIDGET(find_bar_layout, replace_container)

    qt_constants.LAYOUT.SET_ON_WIDGET(find_bar_container, find_bar_layout)

    -- Store find bar refs
    M.find_bar = {
        container = find_bar_container,
        find_edit = find_edit,
        replace_edit = replace_edit,
        replace_container = replace_container,
        attr_combo = attr_combo,
        match_label = match_label,
        rep_btn = rep_btn,
        rep_find_btn = rep_find_btn,
        rep_all_btn = rep_all_btn,
        visible = false,
    }

    -- Wire find bar handlers
    local find_state = require("core.find_state")
    local find_log = require("core.logger").for_area("ui.find")

    local function update_match_label()
        local count = find_state.get_match_count()
        local idx = find_state.get_current_index()
        qt_constants.PROPERTIES.SET_TEXT(match_label, string.format("%d/%d", idx, count))
    end
    M._update_match_label = update_match_label

    local function do_browser_find(navigate)
        local value = qt_constants.PROPERTIES.GET_TEXT(find_edit)
        if not value or value == "" then return false end
        local column = qt_constants.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(attr_combo)
        find_log.event("browser_find: column=%s value=%s clips=%d navigate=%s",
            column, value, M.master_clips and #M.master_clips or 0, tostring(navigate))
        local clips = M:get_clips()
        find_state.execute(clips, {column = column, operator = "contains", value = value})
        update_match_label()
        if navigate ~= false then
            local match = find_state.get_current_match()
            if match then M:navigate_to_clip(match) end
        end
        return true
    end

    local function do_browser_next()
        if not find_state.is_active() then
            if not do_browser_find() then return end
            return
        end
        find_state.next()
        update_match_label()
        local match = find_state.get_current_match()
        if match then M:navigate_to_clip(match) end
    end

    local function do_browser_prev()
        if not find_state.is_active() then
            if not do_browser_find() then return end
            -- Go to last match instead of first
            if find_state.get_match_count() > 0 then
                find_state.previous()  -- wraps from 1 to last
                update_match_label()
                local match = find_state.get_current_match()
                if match then M:navigate_to_clip(match) end
            end
            return
        end
        find_state.previous()
        update_match_label()
        local match = find_state.get_current_match()
        if match then M:navigate_to_clip(match) end
    end

    local function do_browser_select_all()
        if not find_state.is_active() then
            if not do_browser_find() then return end
        end
        local ids = find_state.get_matches()
        find_log.event("browser_select_all: %d matches", #ids)
        if #ids > 0 then M:select_clips(ids) end
        update_match_label()
    end

    local function has_replace()
        local text = qt_constants.PROPERTIES.GET_TEXT(replace_edit)
        return text and text ~= ""
    end

    local function do_browser_replace()
        if not has_replace() or not find_state.is_active() then return end
        local current = find_state.get_current_match()
        if not current then return end
        local cm = require("core.command_manager")
        cm.execute("ReplaceClipProperty", {
            clip_id = current,
            column = qt_constants.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(attr_combo),
            find_value = qt_constants.PROPERTIES.GET_TEXT(find_edit),
            replace_value = qt_constants.PROPERTIES.GET_TEXT(replace_edit),
            project_id = M.project_id,
        })
    end

    local function do_browser_replace_and_find()
        do_browser_replace()
        do_browser_next()
    end

    local function do_browser_replace_all()
        if not has_replace() then return end
        if not find_state.is_active() then
            if not do_browser_find() then return end
        end
        local ids = find_state.get_matches()
        if #ids == 0 then return end
        local cm = require("core.command_manager")
        cm.execute("ReplaceAllClipProperties", {
            clip_ids = ids,
            column = qt_constants.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(attr_combo),
            find_value = qt_constants.PROPERTIES.GET_TEXT(find_edit),
            replace_value = qt_constants.PROPERTIES.GET_TEXT(replace_edit),
            project_id = M.project_id,
        })
        update_match_label()
    end

    -- Button handlers
    local next_h = "__browser_find_next"
    _G[next_h] = do_browser_next
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(next_btn, next_h)

    local prev_h = "__browser_find_prev"
    _G[prev_h] = do_browser_prev
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(prev_btn, prev_h)

    local all_h = "__browser_find_all"
    _G[all_h] = do_browser_select_all
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(all_btn, all_h)

    local rep_h = "__browser_find_rep"
    _G[rep_h] = do_browser_replace
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(rep_btn, rep_h)

    local repf_h = "__browser_find_rep_find"
    _G[repf_h] = do_browser_replace_and_find
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(rep_find_btn, repf_h)

    local repa_h = "__browser_find_rep_all"
    _G[repa_h] = do_browser_replace_all
    qt_constants.CONTROL.SET_BUTTON_CLICK_HANDLER(rep_all_btn, repa_h)

    -- Monitor replace field for enable/disable
    _G["__browser_find_replace_changed"] = function()
        local has_text = has_replace()
        qt_constants.CONTROL.SET_ENABLED(rep_btn, has_text)
        qt_constants.CONTROL.SET_ENABLED(rep_find_btn, has_text)
        qt_constants.CONTROL.SET_ENABLED(rep_all_btn, has_text)
        -- Show/hide replace row based on content
        if qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
            qt_constants.DISPLAY.SET_VISIBLE(replace_container, has_text)
        end
    end
    qt_set_line_edit_text_changed_handler(replace_edit, "__browser_find_replace_changed")

    -- Live search: execute find as user types, update match count
    _G["__browser_find_text_changed"] = function()
        local value = qt_constants.PROPERTIES.GET_TEXT(find_edit)
        if not value or value == "" then
            find_state.clear()
            qt_constants.PROPERTIES.SET_TEXT(match_label, "")
            return
        end
        do_browser_find(false)  -- count only, don't navigate (keeps focus in field)
    end
    qt_set_line_edit_text_changed_handler(find_edit, "__browser_find_text_changed")

    -- Re-run find when attribute column changes
    -- luacheck: globals qt_set_combobox_change_handler
    _G["__browser_find_attr_changed"] = function()
        local value = qt_constants.PROPERTIES.GET_TEXT(find_edit)
        if value and value ~= "" then
            do_browser_find(false)
        end
    end
    qt_set_combobox_change_handler(attr_combo, "__browser_find_attr_changed")

    -- Return in find field → Find Next via QLineEdit::returnPressed signal.
    -- Standard Qt pattern for non-QDialog windows (setDefault only works in QDialog).
    qt_set_line_edit_return_pressed_handler(find_edit, "__browser_find_next")

    -- Start hidden
    if qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
        qt_constants.DISPLAY.SET_VISIBLE(find_bar_container, false)
    end

    qt_constants.LAYOUT.ADD_WIDGET(layout, find_bar_container)
    qt_constants.LAYOUT.ADD_WIDGET(layout, tree)

    -- Set layout on container
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)

    -- Store references for later access
    M.tree = tree
    M.container = container

    -- When tree gets focus with nothing selected, select the first item
    local tree_focus_h = register_handler(function(event)
        local focus_in = event and (event == "FocusIn" or event.type == "FocusIn"
            or event == true or event == 1)
        if focus_in and not M.selected_item then
            if qt_constants.CONTROL.GET_TREE_ITEMS_IN_ORDER then
                local items = qt_constants.CONTROL.GET_TREE_ITEMS_IN_ORDER(tree)
                if items and #items > 0 then
                    qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(tree, items[1])
                end
            end
        end
    end)
    qt_set_focus_handler(tree, tree_focus_h)

    -- Install panel focus trap: Tab wraps within panel, Return activates default button
    qt_set_container_default_button(container, next_btn)  -- Return → Find Next via QShortcut

    --- Toggle find bar visibility (called by Find command)
    function M.toggle_find_bar()
        if not M.find_bar then return end
        M.find_bar.visible = not M.find_bar.visible
        if qt_constants.DISPLAY and qt_constants.DISPLAY.SET_VISIBLE then
            qt_constants.DISPLAY.SET_VISIBLE(M.find_bar.container, M.find_bar.visible)
        end
        -- Focus + select all text when showing
        if M.find_bar.visible then
            pcall(qt_set_focus, M.find_bar.find_edit)
            pcall(qt_line_edit_select_all, M.find_bar.find_edit)
        end
    end

    function M.show_find_bar()
        if not M.find_bar then return end
        if M.find_bar.visible then
            -- Already visible — just re-focus and select
            pcall(qt_set_focus, M.find_bar.find_edit)
            pcall(qt_line_edit_select_all, M.find_bar.find_edit)
        else
            M.toggle_find_bar()
        end
    end

    function M.hide_find_bar()
        if not M.find_bar then return end
        if M.find_bar.visible then
            M.toggle_find_bar()
        end
    end

    local media_count = M.master_clips and #M.master_clips or 0
    local sequence_count = 0
    if M.item_lookup then
        for _, info in pairs(M.item_lookup) do
            if info.type == "timeline" then
                sequence_count = sequence_count + 1
            end
        end
    end
    log.event("Project browser created (media=%d timelines=%d)", media_count, sequence_count)

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
    assert(name and name ~= "", "project_browser.set_project_title: name must not be nil or empty")
    local label = M.project_title_widget
    local display = name
    if label and qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_TEXT then
        qt_constants.PROPERTIES.SET_TEXT(label, display)
    else
        M.pending_project_title = display
    end
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

--- Get all selected master clips (for multi-clip Insert/Overwrite).
-- @return table Array of master clip entries from master_clip_map
function M.get_selected_master_clips()
    local clips = {}
    if not M.selected_items then return clips end
    for _, item in ipairs(M.selected_items) do
        if item.type == "master_clip" and item.clip_id then
            local clip = M.master_clip_map[item.clip_id]
            if clip then
                table.insert(clips, clip)
            end
        end
    end
    return clips
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

-- Set the active project ID (call before refresh when switching projects)
function M.set_project_id(project_id)
    assert(project_id and project_id ~= "", "project_browser.set_project_id: project_id required")
    M.project_id = project_id
end

-- Refresh media list from database
function M.refresh()
    ensure_command_listener()
    populate_tree()
    -- Re-run active find against updated data
    local find_state = require("core.find_state")
    if find_state.is_active() and M.find_bar and M.find_bar.find_edit then
        local value = qt_constants.PROPERTIES.GET_TEXT(M.find_bar.find_edit)
        if value and value ~= "" then
            local column = qt_constants.PROPERTIES.GET_COMBOBOX_CURRENT_TEXT(M.find_bar.attr_combo)
            local clips = M:get_clips()
            find_state.execute(clips, {column = column, operator = "contains", value = value})
            if M._update_match_label then M._update_match_label() end
        end
    end
end

handle_tree_drop = function(event)
    assert(type(event) == "table",
        "project_browser.handle_tree_drop: event must be a table, got " .. type(event))
    if type(event.sources) ~= "table" or #event.sources == 0 then
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
            log.warn("Unsupported drag item")
            return true
        end
    end

    if #dragged_bins > 0 and #dragged_clips > 0 then
        log.warn("Mixed drag selections are not supported")
        return true
    end

    local target_info = lookup_item_by_tree_id(event.target_id)
    assert(event.position, "project_browser.handle_tree_drop: event.position is nil")
    local position = event.position:lower()

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
        local project_id = M.project_id or db.get_current_project_id()

        -- Collect bins that actually need moving (with validation)
        local bins_to_move = {}
        for _, bin_info in ipairs(dragged_bins) do
            if bin_info.id ~= new_parent_id then
                if is_descendant(new_parent_id, bin_info.id) then
                    log.warn("Cannot move a bin inside one of its descendants")
                else
                    table.insert(bins_to_move, bin_info.id)
                end
            end
        end

        if #bins_to_move == 0 then
            return true
        end

        -- Execute via unified MoveToBin command
        local cmd = Command.create("MoveToBin", project_id)
        cmd:set_parameter("project_id", project_id)
        cmd:set_parameter("entity_ids", bins_to_move)
        cmd:set_parameter("target_bin_id", new_parent_id)
        local result = command_manager.execute_interactive(cmd)

        if not result.success then
            log.warn("Failed to move bin(s): %s", tostring(result.error_message or "unknown error"))
            return true
        end

        -- MVC: refresh directly — command_listener triggers M.refresh() for
        -- MoveToBin, but we also need to focus the target bin after rebuild.
        local focus_bin = dragged_bins[1] and dragged_bins[1].id
        M.refresh()
        if focus_bin and M.focus_bin then
            M.focus_bin(focus_bin, {skip_activate = true})
        end
        return true
    end

    if #dragged_clips > 0 then
        local target_bin_id = resolve_bin_parent(target_info, position)
        local project_id = M.project_id or db.get_current_project_id()

        -- Collect clip_ids that actually need reassignment
        -- Group by source_bin_id since MoveToBin needs explicit source
        local changed_ids = {}
        local source_bin_id = nil
        for _, clip_info in ipairs(dragged_clips) do
            if clip_info.bin_id ~= target_bin_id then
                table.insert(changed_ids, clip_info.clip_id)
                -- All dragged clips come from the same bin (project browser context)
                source_bin_id = clip_info.bin_id
            end
        end

        if #changed_ids == 0 then
            return true
        end

        -- Execute via unified MoveToBin command
        local cmd = Command.create("MoveToBin", project_id)
        cmd:set_parameter("project_id", project_id)
        cmd:set_parameter("entity_ids", changed_ids)
        cmd:set_parameter("source_bin_id", source_bin_id)
        cmd:set_parameter("target_bin_id", target_bin_id)
        local result = command_manager.execute_interactive(cmd)

        if not result.success then
            log.warn("Failed to move clips to bin: %s", tostring(result.error_message or "unknown error"))
        end

        -- MVC: refresh directly, no defer_to_ui timing hack
        local first_clip = dragged_clips[1]
        M.refresh()
        if target_bin_id then
            M.focus_bin(target_bin_id, {skip_activate = true})
        elseif first_clip and first_clip.clip_id then
            local clip_entry = M.master_clip_map and M.master_clip_map[first_clip.clip_id]
            if clip_entry and clip_entry.tree_id and qt_constants.CONTROL.SET_TREE_CURRENT_ITEM then
                qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(M.tree, clip_entry.tree_id, true, true)
            end
        end

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
            local result = command_manager.execute_interactive(ACTIVATE_COMMAND)
            if not result or not result.success then
                log.warn("ActivateBrowserSelection failed: %s", result and result.error_message or "unknown error")
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

-- NOTE: defer_to_ui is legitimate here — Qt tree widget needs one event loop
-- cycle to process the focus/selection before entering inline edit mode.
-- This is a Qt widget interaction requirement, NOT a model/data timing hack.
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

    local result, cmd = command_manager.execute_interactive("NewBin", {
        project_id = project_id,
        name = temp_name,
    })
    if not result or not result.success then
        log.warn("New Bin failed: %s", result and result.error_message or "unknown error")
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

    local result, cmd = command_manager.execute_interactive("CreateSequence", {
        project_id        = project_id,
        name              = temp_name,
        frame_rate        = defaults.frame_rate,
        width             = defaults.width,
        height            = defaults.height,
        audio_sample_rate = defaults.audio_sample_rate,
    })
    if not result or not result.success then
        log.warn("New Sequence failed: %s", result and result.error_message or "unknown error")
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
        log.warn("Context menu unavailable: Qt menu bindings missing")
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
        log.warn("Context menu unavailable: Qt menu bindings missing")
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
                -- Insert requires the master sequence to insert as sequence_id;
                -- execute_interactive only injects active project/sequence/playhead.
                assert(selected_master.clip_id and selected_master.clip_id ~= "",
                    "ProjectBrowser Insert: selected master has no clip_id (master sequence id)")
                command_manager.execute_interactive("Insert", {
                    advance_playhead   = true,
                    sequence_id = selected_master.clip_id,
                })
            end
        })
        table.insert(actions, {
            label = "Reveal in Filesystem",
            handler = function()
                local result = command_manager.execute_interactive("RevealInFilesystem")
                if result and not result.success then
                    log.warn("Reveal in Filesystem failed: %s", result.error_message or "unknown error")
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
                log.warn("Delete failed: nothing selected")
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
        clear_browser_selection()
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
    select_browser_items(collected)
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

    -- Group all deletes into one undo step
    local multi = #M.selected_items > 1
    if multi then
        command_manager.begin_undo_group("Delete Selected")
    end

    local handled_sequences = {}
    for _, item in ipairs(M.selected_items) do
        if item.type == "master_clip" and item.clip_id then
            local clip = M.master_clip_map[item.clip_id]
            if clip then
                local project_id = clip.project_id or M.project_id or db.get_current_project_id()
                assert(project_id and project_id ~= "", "project_browser.delete_selected_items: missing project_id for DeleteMasterClip " .. tostring(item.clip_id))

                -- Check if clip is used in any sequences
                local Clip = require("models.clip")
                local usage = Clip.get_master_sequence_usage(clip.clip_id)

                local force = false
                if #usage > 0 then
                    -- Build message with affected sequences
                    local seq_lines = {}
                    local total_clips = 0
                    for _, u in ipairs(usage) do
                        table.insert(seq_lines, string.format("• %s (%d clip%s)",
                            u.sequence_name, u.clip_count, u.clip_count == 1 and "" or "s"))
                        total_clips = total_clips + u.clip_count
                    end
                    local seq_list = table.concat(seq_lines, "\n")

                    local clip_name = clip.name or clip.clip_id:sub(1, 8)
                    local accepted = qt_constants.DIALOG.SHOW_CONFIRM({
                        title = "Delete Master Clip",
                        message = string.format(
                            'Deleting "%s" will remove %d clip%s from %d sequence%s.',
                            clip_name, total_clips, total_clips == 1 and "" or "s",
                            #usage, #usage == 1 and "" or "s"),
                        informative_text = "Affected sequences:\n" .. seq_list,
                        confirm_text = "Delete Anyway",
                        cancel_text = "Cancel",
                        icon = "warning",
                        default_button = "cancel"
                    })

                    if not accepted then
                        -- User cancelled - skip this clip
                        goto continue_master_clip
                    end
                    force = true
                end

                local result = command_manager.execute_interactive("DeleteMasterClip", {
                    master_sequence_id = clip.clip_id,
                    project_id = project_id,
                    force = force,
                })
                if result and result.success then
                    deleted = deleted + 1
                else
                    log.warn("Delete master clip failed: %s", result and result.error_message or "unknown error")
                    clip_failures = clip_failures + 1
                end
            end
            ::continue_master_clip::
        elseif item.type == "timeline" and item.id then
            local sequence_id = item.id
            if not handled_sequences[sequence_id] then
                handled_sequences[sequence_id] = true
                if sequence_id == "default_sequence" then
                    sequence_failures = sequence_failures + 1
                    log.warn("Delete sequence default_sequence skipped: primary timeline cannot be removed")
                    goto continue_delete_loop
                end

                local project_id = M.project_id or db.get_current_project_id()
                assert(project_id and project_id ~= "", "project_browser.delete_selected_items: missing project_id for DeleteSequence " .. tostring(sequence_id))
                local result = command_manager.execute_interactive("DeleteSequence", {
                    sequence_id = sequence_id,
                    project_id = project_id,
                })
                if result and result.success then
                    deleted = deleted + 1
                else
                    sequence_failures = sequence_failures + 1
                    log.warn("Delete sequence %s failed: %s", tostring(sequence_id), result and result.error_message or "unknown error")
                end
                ::continue_delete_loop::
            end
        elseif item.type == "bin" and item.id then
            local project_id = M.project_id or db.get_current_project_id()
            assert(project_id and project_id ~= "", "project_browser.delete_selected_items: missing project_id for DeleteBin " .. tostring(item.id))
            local result = command_manager.execute_interactive("DeleteBin", {
                ["project_id"] = project_id,
                                ["bin_id"] = item.id,
            })
            if result and result.success then
                deleted = deleted + 1
            else
                bin_failures = bin_failures + 1
                log.warn("Delete bin %s failed: %s", tostring(item.name or item.id), result and result.error_message or "unknown error")
            end
        end
    end

    if multi then
        command_manager.end_undo_group()
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
    select_browser_items({info})
end

function M.focus_master_clip(master_seq_id, opts)
    opts = opts or {}
    if not master_seq_id or master_seq_id == "" then
        return false, "Invalid master sequence id"
    end

    local clip = M.master_clip_map and M.master_clip_map[master_seq_id]
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
        clear_browser_selection()
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
        log.warn("Rename: No selection to rename")
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
        log.warn("Rename: Unsupported selection type '%s'", tostring(item.type))
        return false
    end

    if not tree_id or not target_id then
        log.warn("Rename: Unable to locate selected item in tree")
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
        log.event("Rename: SET_TREE_ITEM_EDITABLE result=%s", tostring(editable_ok))
    else
        log.event("Rename: SET_TREE_ITEM_EDITABLE missing")
    end

    local edit_started = false
    if qt_constants.CONTROL.EDIT_TREE_ITEM and tree_id then
        edit_started = qt_constants.CONTROL.EDIT_TREE_ITEM(M.tree, tree_id, 0)
        log.event("Rename: EDIT_TREE_ITEM result=%s", tostring(edit_started))
    else
        log.event("Rename: EDIT_TREE_ITEM missing")
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

    select_browser_items({sequence_info})

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

-- Legacy executor registration removed - now using command module system
-- (see src/lua/core/commands/activate_browser_selection.lua)

command_scope.register(ACTIVATE_COMMAND, {scope = "panel", panel_id = "project_browser"})

--- Clear state that shouldn't persist across projects
function M.on_project_change(project_id)
    -- Clear all caches
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
    -- Reset sort state so next populate_tree loads from new project settings
    sort_state.loaded = false
    -- Invalidate generation — no valid browser data until populate_tree runs
    M._project_gen = nil
    -- Set new project (refresh happens separately via open_project)
    M.project_id = project_id
end

-- ----------------------------------------------------------------------------
-- MODULE-LEVEL SIGNAL CONNECTS — intentional process-lifetime listeners.
-- All connects below run once per `require` and survive across project
-- switches (the project_changed handler at priority 50 clears per-project
-- state on the same dispatch). NOT A LEAK; do not add disconnects.
-- ----------------------------------------------------------------------------
local Signals = require("core.signals")
Signals.connect("project_changed", M.on_project_change, 50)

-- Sequence-list mutations (CreateSequence, DeleteSequence, importer batch).
-- The browser tree is otherwise built once at project-open and never
-- repopulated, so any newly-created sequence (or undo of a delete) would
-- be invisible until the project was reopened. Project_id mismatch ⇒ noop
-- (signal is for some other open project).
Signals.connect("sequence_list_changed", function(project_id)
    assert(type(project_id) == "string" and project_id ~= "",
        "project_browser: sequence_list_changed emitter must pass non-empty project_id")
    if project_id == M.project_id then
        M.refresh()
    end
end)

-- Per-row refresh for any media-level change. Called from both
-- media_status_changed (offline icon flip) and media_content_changed
-- (bytes rewritten — no status flip, but any cached visual derived
-- from the file, e.g. thumbnails, is stale). Today only the icon path
-- exists; the thumbnail invalidation will land alongside thumbnail
-- rendering and hooks in here.
local function refresh_row_for_path(media_path, status_hint)
    assert(type(media_path) == "string" and media_path ~= "", string.format(
        "project_browser.refresh_row_for_path: media_path must be non-empty string, got %s",
        type(media_path)))
    if status_hint ~= nil then
        assert(type(status_hint) == "table" and type(status_hint.offline) == "boolean",
            "project_browser.refresh_row_for_path: status_hint must be {offline=bool}")
    end
    if not M.tree or not M.item_lookup then return end
    for _, info in pairs(M.item_lookup) do
        if info.type == "master_clip" and info.file_path == media_path then
            if status_hint then info.offline = status_hint.offline end
            assert(info.media_kind, string.format(
                "project_browser: master_clip info missing media_kind (tree_id=%s file_path=%s)",
                tostring(info.tree_id), tostring(info.file_path)))
            qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, info.tree_id,
                pick_clip_icon(info.media_kind, info.offline))
            -- TODO(thumbnails): drop cached thumbnail for info.tree_id here
            -- once the thumbnail cache is landed.
        end
    end
end

-- Reactive media status: update browser icons when file status changes
Signals.connect("media_status_changed", function(media_path, status)
    refresh_row_for_path(media_path, status)
end)

-- Reactive content change: bytes rewritten in place. Status unchanged,
-- but any derived visual (thumbnails when they land) is stale.
Signals.connect("media_content_changed", function(media_path)
    refresh_row_for_path(media_path, nil)
end)

-- Reactive media change: when media records are modified (e.g. relink),
-- refresh browser to update file paths and offline icons.
Signals.connect("media_changed", function(_changed_media_ids)
    if not M.tree then return end
    M.refresh()
end)

-- ============================================================================
-- View interface
-- ============================================================================

function M:navigate_to_clip(clip_id)
    assert(clip_id, "project_browser:navigate_to_clip: clip_id required")
    local clip = M.master_clip_map and M.master_clip_map[clip_id]
    if clip and clip.tree_id and M.tree then
        -- Pass true for no_focus: select + scroll without stealing keyboard focus
        -- (keeps focus in find bar when navigating via Return or arrow buttons)
        qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(M.tree, clip.tree_id, true)
    end
end

function M:select_clips(clip_ids)
    assert(clip_ids, "project_browser:select_clips: clip_ids required")
    if not M.tree or #clip_ids == 0 then return end
    -- Build array of tree_ids from clip_ids
    local tree_ids = {}
    for _, cid in ipairs(clip_ids) do
        local clip = M.master_clip_map and M.master_clip_map[cid]
        if clip and clip.tree_id then
            tree_ids[#tree_ids + 1] = clip.tree_id
        end
    end
    if #tree_ids > 0 and qt_constants.CONTROL.SET_TREE_SELECTED_ITEMS then
        qt_constants.CONTROL.SET_TREE_SELECTED_ITEMS(M.tree, tree_ids)
    elseif #tree_ids > 0 then
        -- Fallback: select first only
        qt_constants.CONTROL.SET_TREE_CURRENT_ITEM(M.tree, tree_ids[1])
    end
end

function M:get_clips()
    local log_pb = require("core.logger").for_area("ui.find")

    -- Build lookup from clip_id → clip_data
    local clip_by_id = {}
    if M.master_clips then
        for _, clip in ipairs(M.master_clips) do
            local media = clip.media or (clip.media_id and M.media_map[clip.media_id]) or {}
            local cid = clip.clip_id or clip.id
            -- Display aggregation; in-memory shapes vary by source (master vs
            -- sequence-derived) and fields may be legitimately nil.
            clip_by_id[cid] = {
                id = cid,
                name = clip.name or media.name or "",  -- lint-allow: R010 display-only
                codec = clip.codec or media.codec or "",  -- lint-allow: R010 display-only
                fps = clip.fps_float or 0,  -- lint-allow: R010 display-only
                duration = clip.duration or 0,  -- lint-allow: R010 display-only
                enabled = clip.enabled ~= false,
                offline = clip.offline == true,
                volume = clip.volume or 1.0,  -- lint-allow: R010 display-only
                width = clip.width or media.width or 0,  -- lint-allow: R010 nullable (audio-only)
                height = clip.height or media.height or 0,  -- lint-allow: R010 nullable (audio-only)
                audio_channels = media.audio_channels or 0,  -- lint-allow: R010 schema DEFAULT 0
                audio_sample_rate = media.audio_sample_rate or 0,  -- lint-allow: R010 nullable (video-only)
                properties = {},
            }
        end
    end

    -- Get tree visual order and build clip_data in that order
    local clip_data = {}
    if M.tree and qt_constants.CONTROL.GET_TREE_ITEMS_IN_ORDER then
        local tree_ids = qt_constants.CONTROL.GET_TREE_ITEMS_IN_ORDER(M.tree)
        for _, tid in ipairs(tree_ids) do
            local info = M.item_lookup and M.item_lookup[tostring(tid)]
            if info and info.type == "master_clip" and info.clip_id then
                local cd = clip_by_id[info.clip_id]
                if cd then
                    clip_data[#clip_data + 1] = cd
                end
            end
        end
    end

    -- Fallback: if no tree or binding missing, return unsorted
    if #clip_data == 0 then
        for _, cd in pairs(clip_by_id) do
            clip_data[#clip_data + 1] = cd
        end
    end

    log_pb.event("project_browser:get_clips count=%d", #clip_data)
    return clip_data
end

return M
