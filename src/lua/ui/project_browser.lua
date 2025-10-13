-- Project Browser - Media library and bin management
-- Shows imported media files, allows drag-to-timeline
-- Mimics DaVinci Resolve Media Pool style

local M = {}
local db = require("core.database")
local ui_constants = require("core.ui_constants")

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

    -- Load bins and media from database
    local bins = db.load_bins()
    local media_items = db.load_media()
    print("Loading " .. #bins .. " bins and " .. #media_items .. " media items into project browser")

    -- Helper to get bin tag for a media item
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

    -- Build a map of bin_id -> tree_index for hierarchy
    local bin_tree_map = {}

    -- Helper to format duration for display (ms → HH:MM:SS or MM:SS)
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

    -- Helper to format timestamp for display
    local function format_date(timestamp)
        if not timestamp or timestamp == 0 then
            return ""
        end
        return os.date("%b %d %Y", timestamp)
    end

    -- Helper function to add bins recursively
    local function add_bin_to_tree(bin, parent_tree_idx)
        local display_name = "▶ " .. bin.name
        local tree_idx

        if parent_tree_idx then
            -- Add as child of parent bin (bins don't have metadata columns)
            tree_idx = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(tree, parent_tree_idx, {display_name, "", "", "", "", ""})
        else
            -- Add as root level bin
            tree_idx = qt_constants.CONTROL.ADD_TREE_ITEM(tree, {display_name, "", "", "", "", ""})
        end

        bin_tree_map[bin.id] = tree_idx
        return tree_idx
    end

    -- First pass: Add all root level bins
    for _, bin in ipairs(bins) do
        if not bin.parent_id then
            add_bin_to_tree(bin, nil)
        end
    end

    -- Second pass: Add nested bins
    for _, bin in ipairs(bins) do
        if bin.parent_id and bin_tree_map[bin.parent_id] then
            add_bin_to_tree(bin, bin_tree_map[bin.parent_id])
        end
    end

    -- Add root level media (not in any bin)
    for _, media in ipairs(media_items) do
        local bin_tag = get_bin_tag(media)
        if not bin_tag then
            -- Extract real metadata from Media model
            local duration_str = format_duration(media.duration)
            local resolution_str = (media.width and media.height and media.width > 0)
                and string.format("%dx%d", media.width, media.height)
                or ""
            local fps_str = (media.frame_rate and media.frame_rate > 0)
                and string.format("%.2f", media.frame_rate)
                or ""
            local codec_str = media.codec or ""
            local date_str = format_date(media.modified_at or media.created_at)

            qt_constants.CONTROL.ADD_TREE_ITEM(tree, {
                media.name or media.file_name,
                duration_str,
                resolution_str,
                fps_str,
                codec_str,
                date_str
            })
        end
    end

    -- Add media to their respective bins
    for _, media in ipairs(media_items) do
        local bin_tag = get_bin_tag(media)
        if bin_tag then
            -- Find the bin with matching tag path
            for _, bin in ipairs(bins) do
                -- Match the bin's full path (reconstruct from parent chain)
                local bin_path_parts = {}
                local current_bin = bin
                while current_bin do
                    table.insert(bin_path_parts, 1, current_bin.name)
                    -- Find parent
                    local parent = nil
                    if current_bin.parent_id then
                        for _, b in ipairs(bins) do
                            if b.id == current_bin.parent_id then
                                parent = b
                                break
                            end
                        end
                    end
                    current_bin = parent
                end
                local bin_path = table.concat(bin_path_parts, "/")

                if bin_path == bin_tag and bin_tree_map[bin.id] then
                    -- Extract real metadata from Media model
                    local duration_str = format_duration(media.duration)
                    local resolution_str = (media.width and media.height and media.width > 0)
                        and string.format("%dx%d", media.width, media.height)
                        or ""
                    local fps_str = (media.frame_rate and media.frame_rate > 0)
                        and string.format("%.2f", media.frame_rate)
                        or ""
                    local codec_str = media.codec or ""
                    local date_str = format_date(media.modified_at or media.created_at)

                    qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(tree, bin_tree_map[bin.id], {
                        media.name or media.file_name,
                        duration_str,
                        resolution_str,
                        fps_str,
                        codec_str,
                        date_str
                    })
                    break
                end
            end
        end
    end

    qt_constants.LAYOUT.ADD_WIDGET(layout, tree)

    -- Set layout on container
    qt_constants.LAYOUT.SET_ON_WIDGET(container, layout)

    -- Store references for later access
    M.tree = tree
    M.media_items = media_items
    M.insert_button = insert_btn
    M.container = container

    print("✅ Project browser created with " .. #media_items .. " media items")

    return container
end

-- Set timeline panel reference (called by correct_layout after both are created)
function M.set_timeline_panel(timeline_panel_mod)
    M.timeline_panel = timeline_panel_mod

    -- Connect insert button now that we have timeline reference
    if M.insert_button then
        -- Store callback globally for Qt signal system
        _G.project_browser_insert_handler = function()
            local selected_index = qt_constants.CONTROL.GET_TREE_SELECTED_INDEX(M.tree)
            if selected_index < 0 or selected_index >= #M.media_items then
                print("⚠️  No media item selected")
                return
            end

            local media = M.media_items[selected_index + 1]  -- Lua 1-indexed
            print(string.format("📥 Inserting media to timeline: %s", media.name))

            -- Use command system to insert media as clip
            local command_manager = require("core.command_manager")
            local Command = require("command")

            -- Find first video track
            local tracks = require("core.database").load_tracks("default_sequence")
            local target_track = nil
            for _, track in ipairs(tracks) do
                if track.track_type == "VIDEO" then
                    target_track = track
                    break
                end
            end

            if not target_track then
                print("❌ No video track found")
                return
            end

            -- Get timeline state to find insert position (use playhead or end of timeline)
            local timeline_state = M.timeline_panel.get_state()
            local insert_time = timeline_state.playhead_time or 0

            -- Create Insert command with full media duration
            local source_in = 0
            local source_out = media.duration
            local duration = source_out - source_in

            local cmd = Command.create("Insert", "default_project")
            cmd:set_parameter("track_id", target_track.id)
            cmd:set_parameter("media_id", media.id)
            cmd:set_parameter("insert_time", insert_time)
            cmd:set_parameter("duration", duration)
            cmd:set_parameter("source_in", source_in)
            cmd:set_parameter("source_out", source_out)

            local success, result = pcall(function()
                return command_manager.execute(cmd)
            end)

            if success and result and result.success then
                print("✅ Media inserted to timeline")
            else
                print(string.format("❌ Failed to insert: %s", result and result.error_message or "unknown"))
            end
        end

        -- Register the handler with Qt
        qt_set_button_click_handler(M.insert_button, "project_browser_insert_handler")
    end
end

-- Get selected media item
function M.get_selected_media()
    if not M.tree then
        return nil
    end

    local selected_index = qt_constants.CONTROL.GET_TREE_SELECTED_INDEX(M.tree)
    if selected_index >= 0 and selected_index < #M.media_items then
        return M.media_items[selected_index + 1]  -- Lua is 1-indexed
    end

    return nil
end

-- Refresh media list from database
function M.refresh()
    if not M.tree then
        return
    end

    -- Clear existing items
    qt_constants.CONTROL.CLEAR_TREE(M.tree)

    -- Reload from database
    local bins = db.load_bins()
    M.media_items = db.load_media()

    -- Helper to get bin tag for a media item
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

    -- Build a map of bin_id -> tree_index for hierarchy
    local bin_tree_map = {}

    -- Helper function to add bins recursively
    local function add_bin_to_tree(bin, parent_tree_idx)
        local display_name = "▶ " .. bin.name
        local tree_idx

        if parent_tree_idx then
            tree_idx = qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(M.tree, parent_tree_idx, {display_name, "", ""})
        else
            tree_idx = qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, {display_name, "", ""})
        end

        bin_tree_map[bin.id] = tree_idx
        return tree_idx
    end

    -- Add root level bins
    for _, bin in ipairs(bins) do
        if not bin.parent_id then
            add_bin_to_tree(bin, nil)
        end
    end

    -- Add nested bins
    for _, bin in ipairs(bins) do
        if bin.parent_id and bin_tree_map[bin.parent_id] then
            add_bin_to_tree(bin, bin_tree_map[bin.parent_id])
        end
    end

    -- Add root level media
    for _, media in ipairs(M.media_items) do
        local bin_tag = get_bin_tag(media)
        if not bin_tag then
            local date_str = "Mon Aug 22"
            qt_constants.CONTROL.ADD_TREE_ITEM(M.tree, {
                media.file_name,
                date_str,
                date_str
            })
        end
    end

    -- Add media to bins
    for _, media in ipairs(M.media_items) do
        local bin_tag = get_bin_tag(media)
        if bin_tag then
            -- Find the bin with matching tag path
            for _, bin in ipairs(bins) do
                -- Match the bin's full path (reconstruct from parent chain)
                local bin_path_parts = {}
                local current_bin = bin
                while current_bin do
                    table.insert(bin_path_parts, 1, current_bin.name)
                    -- Find parent
                    local parent = nil
                    if current_bin.parent_id then
                        for _, b in ipairs(bins) do
                            if b.id == current_bin.parent_id then
                                parent = b
                                break
                            end
                        end
                    end
                    current_bin = parent
                end
                local bin_path = table.concat(bin_path_parts, "/")

                if bin_path == bin_tag and bin_tree_map[bin.id] then
                    local date_str = "Mon Aug 22"
                    qt_constants.CONTROL.ADD_TREE_CHILD_ITEM(M.tree, bin_tree_map[bin.id], {
                        media.file_name,
                        date_str,
                        date_str
                    })
                    break
                end
            end
        end
    end

    print("✅ Project browser refreshed with " .. #bins .. " bins and " .. #M.media_items .. " media items")
end

return M
