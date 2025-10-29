-- Project Browser - Media library and bin management
-- Shows imported media files, allows drag-to-timeline
-- Mimics DaVinci Resolve Media Pool style

local M = {}
local db = require("core.database")
local ui_constants = require("core.ui_constants")
local focus_manager = require("ui.focus_manager")
local command_manager = require("core.command_manager")
local command_scope = require("core.command_scope")
local browser_state = require("ui.project_browser.browser_state")

local handler_seq = 0

local function register_handler(callback)
    handler_seq = handler_seq + 1
    local name = "__project_browser_handler_" .. handler_seq
    _G[name] = function(...)
        callback(...)
    end
    return name
end

M.item_lookup = {}
M.media_map = {}
M.sequence_map = {}
M.selected_item = nil
M.selected_items = {}
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
    elseif item_info.type == "clip" then
        local media = M.media_map[item_info.media_id]
        if not media then
            return false, "Media metadata missing"
        end

        if M.viewer_panel and M.viewer_panel.show_source_clip then
            M.viewer_panel.show_source_clip(media)
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
    local ok, encoded = pcall(qt_json_encode, info)
    if ok and qt_constants.CONTROL.SET_TREE_ITEM_DATA then
        qt_constants.CONTROL.SET_TREE_ITEM_DATA(tree, tree_id, encoded)
    end
    M.item_lookup[tostring(tree_id)] = info
end

local function format_duration(duration_ms)
    if not duration_ms or duration_ms == 0 then
        return "--:--"
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

    qt_constants.CONTROL.CLEAR_TREE(M.tree)
    M.item_lookup = {}
    M.media_map = {}
    M.sequence_map = {}
    M.selected_item = nil
    M.selected_items = {}
    browser_state.clear_selection()

    local project_id = M.project_id or db.get_current_project_id()
    M.project_id = project_id

    local bins = db.load_bins()
    local media_items = db.load_media()
    local sequences = db.load_sequences(project_id)

    M.media_items = media_items
    for _, media in ipairs(media_items) do
        M.media_map[media.id] = media
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
    end

    local function add_bin(bin, parent_id)
        local display_name = "▶ " .. bin.name
        local tree_id
        if parent_id then
            tree_id = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(M.tree, parent_id, {display_name, "", "", "", "", ""})
        else
            tree_id = qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, {display_name, "", "", "", "", ""})
        end
        store_tree_item(M.tree, tree_id, {type = "bin", id = bin.id})
        if qt_constants.CONTROL.SET_TREE_ITEM_ICON then
            qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, tree_id, "bin")
        end
        bin_tree_map[bin.id] = tree_id
        return tree_id
    end

    -- Root sequences
    for _, sequence in ipairs(sequences) do
        local duration_str = format_duration(sequence.duration)
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

    local function add_media_item(parent_id, media)
        local duration_str = format_duration(media.duration)
        local resolution_str = (media.width and media.height and media.width > 0)
            and string.format("%dx%d", media.width, media.height)
            or ""
        local fps_str = (media.frame_rate and media.frame_rate > 0)
            and string.format("%.2f", media.frame_rate)
            or ""
        local codec_str = media.codec or ""
        local date_str = format_date(media.modified_at or media.created_at)

        local columns = {
            media.name or media.file_name,
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
            type = "clip",
            media_id = media.id,
            name = media.name or media.file_name,
            file_path = media.file_path,
            duration = media.duration,
            frame_rate = media.frame_rate,
            width = media.width,
            height = media.height,
            codec = media.codec,
            metadata = media.metadata
        })
        if qt_constants.CONTROL.SET_TREE_ITEM_ICON then
            qt_constants.CONTROL.SET_TREE_ITEM_ICON(M.tree, tree_id, "clip")
        end
    end

    -- Root media
    for _, media in ipairs(media_items) do
        local bin_tag = get_bin_tag(media)
        if not bin_tag then
            add_media_item(nil, media)
        end
    end

    -- Media inside bins
    for _, media in ipairs(media_items) do
        local bin_tag = get_bin_tag(media)
        if bin_tag then
            local bin_id = bin_path_lookup[bin_tag]
            local parent_tree = bin_id and bin_tree_map[bin_id]
            if parent_tree then
                add_media_item(parent_tree, media)
            else
                add_media_item(nil, media)
            end
        end
    end
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

        browser_state.update_selection(collected, {
            media_lookup = M.media_map,
            sequence_lookup = M.sequence_map
        })

        if focus_manager and focus_manager.focus_panel then
            focus_manager.focus_panel("project_browser")
        else
            focus_manager.set_focused_panel("project_browser")
        end
    end)
    if qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER then
        qt_constants.CONTROL.SET_TREE_SELECTION_HANDLER(tree, selection_handler)
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

    local media_count = M.media_items and #M.media_items or 0
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
function M.get_selected_media()
    if not M.selected_items or #M.selected_items == 0 then
        return nil
    end
    local first = M.selected_items[1]
    if not first or first.type ~= "clip" then
        return nil
    end
    return M.media_map[first.media_id]
end

-- Refresh media list from database
function M.refresh()
    populate_tree()
end

function M.insert_selected_to_timeline()
    if not M.timeline_panel then
        print("⚠️  Timeline panel not available")
        return
    end

    local media = M.get_selected_media()
    if not media then
        print("⚠️  No media item selected")
        return
    end

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
    local source_in = 0
    local source_out = media.duration or 0
    local duration = source_out - source_in
    if duration <= 0 then
        print("⚠️  Media duration is invalid")
        return
    end

    local cmd = Command.create("Insert", project_id)
    cmd:set_parameter("sequence_id", sequence_id)
    cmd:set_parameter("track_id", track_id)
    cmd:set_parameter("media_id", media.id)
    cmd:set_parameter("insert_time", insert_time)
    cmd:set_parameter("duration", duration)
    cmd:set_parameter("source_in", source_in)
    cmd:set_parameter("source_out", source_out)

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

function M.activate_selection()
    if not M.selected_item then
        return false, "No selection"
    end
    return activate_item(M.selected_item)
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
